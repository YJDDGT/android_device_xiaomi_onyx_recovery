#!/system/bin/sh

SCRIPT_NAME="$(basename "$0")"

LOGMSG() {
    echo "I:$@" >> /tmp/recovery.log
}

LOGMSG "---$SCRIPT_NAME start---"

LOGMSG "Resetting SPL date to prevent anti-rollback protection..."
resetprop ro.build.version.security_patch 2023-12-31

# Format /metadata for DFE users to ensure VABC works properly!
LOGMSG "Formatting /metadata for DFE users..."
umount /metadata 2>/dev/null
make_f2fs -f /dev/block/bootdevice/by-name/metadata 2>/dev/null
mount -t f2fs /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null || mount -t ext4 /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null
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
