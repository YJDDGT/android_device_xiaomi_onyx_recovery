#!/system/bin/sh

SCRIPT_NAME="$(basename "$0")"

LOGMSG() {
    echo "I:$@" >> /tmp/recovery.log
}

LOGMSG "---$SCRIPT_NAME start---"

LOGMSG "Resetting SPL date to prevent anti-rollback protection..."
resetprop ro.build.version.security_patch 2023-12-31

# Ensure /metadata is mounted so update_engine can create snapshots
LOGMSG "Ensuring /metadata is mounted..."
mount /metadata 2>/dev/null || mount -t f2fs /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null || mount -t ext4 /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null
mkdir -p /metadata/ota/snapshots
chmod -R 0750 /metadata/ota
LOGMSG "/metadata/ota/snapshots created to prevent Error 7 on DFE users!"

LOGMSG "VABC DFE Fix: Fixing liblp by-name resolution bug via direct symlinks..."

# Symlink all raw block devices directly to /dev/block/by-name/ so liblp can find them!
for dev in /dev/block/sd* /dev/block/mmcblk* /dev/block/loop* /dev/block/dm-*; do
    if [ -b "$dev" ]; then
        base=$(basename "$dev")
        ln -sf "$dev" "/dev/block/by-name/$base"
    fi
done

LOGMSG "Initial symlinks created."

# update_engine_sideload creates dm-snapshot devices mid-flight.
# We run a background daemon to continuously symlink new dm-* devices to by-name.
(
    while true; do
        for dev in /dev/block/dm-*; do
            if [ -b "$dev" ]; then
                base=$(basename "$dev")
                if [ ! -L "/dev/block/by-name/$base" ]; then
                    ln -sf "$dev" "/dev/block/by-name/$base" 2>/dev/null
                fi
            fi
        done
        sleep 0.5
    done
) &
echo $! > /tmp/fox_symlink_daemon.pid

LOGMSG "Background daemon started to link newly created dm-* devices. liblp will now resolve all raw block devices!"

LOGMSG "Detecting active boot slot..."
slot="$(getprop ro.boot.slot_suffix)"
LOGMSG "Active boot slot: $slot"

LOGMSG "Backing up recovery.img before ROM overwrites..."
dd if="/dev/block/bootdevice/by-name/recovery${slot}" of="/tmp/fox_backup.img" bs=1M
sync

LOGMSG "---$SCRIPT_NAME end---"

LOGMSG "Cleaning up dynamic partition mounts to prevent update_engine Error 1..."

# Kill FBE daemons that keep /vendor busy
for svc in qseecomd ssgtzd vendor.health-default vendor.weaver-nxp vendor.gatekeeper-1-0 vendor.secure_element_hal_service vendor.keymint-default; do
    stop $svc
done

# Kill any lingering processes using dynamic partitions
for pid in $(lsof | grep -E '/vendor|/system_root|/system_ext|/product|/odm' | awk '{print $2}' | sort -u); do
    kill -9 $pid 2>/dev/null
done

# Force recursively unmount dynamic partitions
for part in /vendor /system_root /system_ext /product /odm; do
    umount -R $part 2>/dev/null
    umount -l $part 2>/dev/null
done

LOGMSG "Dynamic partitions forcefully unmounted."

LOGMSG "Wiping Virtual A/B state to ensure clean OTA flash..."

# Force unmount any existing tmpfs or ext4 metadata to ensure we mount the real one
umount /metadata 2>/dev/null

# Mount /metadata as writable
mount -t f2fs /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null || mount -t ext4 /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null
mount -o remount,rw /metadata 2>/dev/null

# Clean ALL stale OTA state and massive log files that fill up /metadata
rm -rf /metadata/ota/*
rm -rf /metadata/gsi/ota/*
rm -f /metadata/boot_logcat.txt

# Create ALL directories required by update_engine_sideload:
# - /metadata/ota/snapshots: for per-partition snapshot state files
# - /metadata/gsi/ota: for COW image metadata tmpfiles (liblp WriteToImageFile)
mkdir -p /metadata/ota/snapshots
mkdir -p /metadata/gsi/ota
chmod -R 0750 /metadata/ota
chmod -R 0750 /metadata/gsi/ota

# Sync to disk so update_engine's internal remount sees these directories
sync

# UNMOUNT /metadata here!
# We MUST unmount it so update_engine_sideload can mount it natively using fs_mgr.
# This prevents update_engine from thinking it's unmounted due to namespace/symlink issues.
umount /metadata 2>/dev/null
LOGMSG "Virtual A/B state wiped. /metadata unmounted for update_engine."


