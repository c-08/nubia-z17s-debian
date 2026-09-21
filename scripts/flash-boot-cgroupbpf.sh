#!/bin/sh
# flash-boot-cgroupbpf.sh -- write the new boot image + modules and verify.
# Run from the RUNNING Debian system: /dev/sde18 is not mounted there (the kernel lives in
# RAM and the rootfs is sda10), so overwriting it is safe and needs no TWRP.
set -u
IMG=/root/boot-new-cgroupbpf.img
DEV=/dev/sde18
BAK=/root/boot-prev-cgroupbpf.img
MODS=/root/modules-new-cgroupbpf.tar.gz
KVER=6.12.95+

echo "=== 0) inputs ==="
ls -l "$IMG" "$MODS" || exit 1

echo "=== 1) sanity: boot partition must NOT be mounted ==="
n=$(grep -c sde18 /proc/mounts)
echo "mounts containing sde18: $n  (must be 0)"
[ "$n" != "0" ] && { echo "ABORT: sde18 is mounted"; exit 1; }
lsblk "$DEV" 2>/dev/null || true

echo "=== 2) backup current boot partition ==="
dd if="$DEV" of="$BAK" bs=4M 2>&1 | tail -2
ls -l "$BAK"
md5sum "$BAK"

echo "=== 3) write new boot image ==="
dd if="$IMG" of="$DEV" bs=4M conv=fsync 2>&1 | tail -2
sync

echo "=== 4) readback verify (first $(stat -c %s "$IMG") bytes) ==="
SZ=$(stat -c %s "$IMG")
dd if="$DEV" bs=4M count=9 2>/dev/null | head -c "$SZ" | md5sum
md5sum "$IMG"

echo "=== 5) install modules ==="
mkdir -p /root/modules-backup-cgroupbpf
if [ ! -f /root/modules-backup-cgroupbpf/done ]; then
    tar czf /root/modules-backup-cgroupbpf/modules-prev.tar.gz -C /lib/modules "$KVER" 2>/dev/null
    touch /root/modules-backup-cgroupbpf/done
fi
tar xzf "$MODS" -C /lib/modules/
ls -d /lib/modules/*/
echo "g_serial.ko: $(ls /lib/modules/$KVER/kernel/drivers/usb/gadget/legacy/g_serial.ko 2>/dev/null || echo MISSING)"
command -v depmod >/dev/null && depmod "$KVER" && echo "depmod ok"

echo "=== 6) boot args (unchanged) ==="
cat /proc/cmdline

echo "FLASH_DONE"
