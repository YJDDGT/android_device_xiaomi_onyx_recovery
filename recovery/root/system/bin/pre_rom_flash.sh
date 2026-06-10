#!/system/bin/sh

SCRIPT_NAME="$(basename "$0")"

LOGMSG() {
    echo "I:$@" >> /tmp/recovery.log
}

LOGMSG "---$SCRIPT_NAME start---"

LOGMSG "Resetting SPL date to prevent anti-rollback protection..."
resetprop ro.build.version.security_patch 2023-12-31

# LOGMSG "Formatting /metadata..."
# make_f2fs /dev/block/bootdevice/by-name/metadata

LOGMSG "Detecting active boot slot..."
slot="$(getprop ro.boot.slot_suffix)"
LOGMSG "Active boot slot: $slot"

LOGMSG "Ensuring /metadata is mounted for Virtual A/B Update Engine..."
mount /metadata 2>/dev/null || mount -t f2fs /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null || mount -t ext4 /dev/block/bootdevice/by-name/metadata /metadata 2>/dev/null
mkdir -p /metadata/ota/snapshots
chmod -R 0750 /metadata/ota
LOGMSG "/metadata/ota/snapshots created to prevent Error 7 on DFE users!"

LOGMSG "VABC DFE Fix: Fixing liblp by-name resolution bug via Bind-Mount Hijack..."

# liblp on Android 14 has a bug where it searches for the raw block device name (e.g. sda34 or loop0)
# inside /dev/block/by-name/, which ueventd does not populate. We will hijack the directory.
mkdir -p /tmp/fake_by_name
cp -P /dev/block/by-name/* /tmp/fake_by_name/ 2>/dev/null

# Symlink all raw block devices so liblp can find them!
for dev in /dev/block/sd* /dev/block/mmcblk* /dev/block/loop* /dev/block/dm-*; do
    if [ -b "$dev" ]; then
        base=$(basename "$dev")
        ln -s "$dev" "/tmp/fake_by_name/$base"
    fi
done

# Bind mount over the protected ueventd directory
mount -o bind /tmp/fake_by_name /dev/block/by-name

LOGMSG "Bind-Mount Hijack active. liblp will now resolve all raw block devices!"

LOGMSG "Backing up recovery.img before ROM overwrites..."
dd if="/dev/block/bootdevice/by-name/recovery${slot}" of="/tmp/fox_backup.img" bs=1M
sync

LOGMSG "---$SCRIPT_NAME end---"
