#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/common.sh"

for cmd in abootimg cpio file gzip java rsync sha256sum; do
	need_cmd "$cmd"
done

IMAGE="${IMAGE:-$BUILD_DIR/Image.gz-$KVER_EXPECTED}"
DTB="${DTB:-$BUILD_DIR/msm8998-nubia-nx595j.dtb}"
MODULES="$BUILD_DIR/driver-bundle/lib/modules/$KVER_EXPECTED"
FIRMWARE="$ASSETS_DIR/driver-bundle/lib/firmware"
REFERENCE="${REFERENCE_BOOT:-$ASSETS_DIR/boot-reference/boot-nx595j-6.12-audio-qdsp-tas2555-speaker-v12p2-signed.img}"
SIGN_DIR="$ASSETS_DIR/signing"
WORK="$BUILD_DIR/boot-work"
UNSIGNED="$BUILD_DIR/boot-nx595j-debian13-unsigned.img"
SIGNED="$BUILD_DIR/boot-nx595j-debian13-signed.img"

assert_build_target "$WORK"
need_file "$IMAGE"
need_file "$DTB"
need_dir "$MODULES"
need_dir "$FIRMWARE"
need_file "$REFERENCE"
need_file "$SIGN_DIR/BootSignature.jar"
need_file "$SIGN_DIR/verity.pk8"
need_file "$SIGN_DIR/verity.x509.der"

rm -rf "$WORK"
mkdir -p "$WORK/ramdisk"
abootimg -x "$REFERENCE" "$WORK/reference.cfg" \
	"$WORK/reference.kernel" "$WORK/reference.ramdisk"

ramdisk_type="$(file -b "$WORK/reference.ramdisk")"
case "$ramdisk_type" in
	*gzip*)
		gzip -dc "$WORK/reference.ramdisk" | \
			(cd "$WORK/ramdisk" && sudo cpio -idm --no-absolute-filenames)
		RAMDISK_COMPRESSION=gzip
		;;
	*cpio*)
		(cd "$WORK/ramdisk" && sudo cpio -idm --no-absolute-filenames) \
			< "$WORK/reference.ramdisk"
		RAMDISK_COMPRESSION=none
		;;
	*) die "unsupported reference ramdisk: $ramdisk_type" ;;
esac

sudo rm -rf "$WORK/ramdisk/lib/modules/$KVER_EXPECTED"
sudo mkdir -p "$WORK/ramdisk/lib/modules" "$WORK/ramdisk/lib/firmware"
sudo rsync -a "$MODULES/" \
	"$WORK/ramdisk/lib/modules/$KVER_EXPECTED/"
sudo rsync -a --delete "$FIRMWARE/" "$WORK/ramdisk/lib/firmware/"
sudo find "$WORK/ramdisk/lib/modules" -type f -name 'ipa.ko*' -delete

RAMDISK="$WORK/ramdisk.cpio"
(cd "$WORK/ramdisk" && sudo find . -print0 | \
	sudo cpio --null -o --format=newc) > "$RAMDISK"
if [[ "$RAMDISK_COMPRESSION" == gzip ]]; then
	gzip -9 -f "$RAMDISK"
	RAMDISK="$RAMDISK.gz"
fi
sudo chown "$(id -u):$(id -g)" "$RAMDISK"

cat "$IMAGE" "$DTB" "$DTB" "$DTB" > "$WORK/Image.gz-dtb"
cat > "$WORK/bootimg.cfg" <<'EOF'
bootsize = 0x4000000
pagesize = 0x1000
kerneladdr = 0x8000
ramdiskaddr = 0x1000000
secondaddr = 0xf00000
tagsaddr = 0x100
name = z17s-6.12
cmdline = clk_ignore_unused loglevel=8 console=tty0 console=ttyGS0,115200n8 fbcon=map:0 no_console_suspend keep_bootcon panic_on_oops=0 panic=86400 nowatchdog deferred_probe_timeout=30 scsi_mod.scan=sync rootdelay=5 root=/dev/ram0 rw init=/init rdinit=/init androidboot.hardware=qcom androidboot.bootdevice=1da4000.ufshc swiotlb=2048 z17s.rootfs=userdata
EOF

rm -f "$UNSIGNED" "$SIGNED"
abootimg --create "$UNSIGNED" -f "$WORK/bootimg.cfg" \
	-k "$WORK/Image.gz-dtb" -r "$RAMDISK"
java -jar "$SIGN_DIR/BootSignature.jar" /boot "$UNSIGNED" \
	"$SIGN_DIR/verity.pk8" "$SIGN_DIR/verity.x509.der" "$SIGNED"
java -jar "$SIGN_DIR/BootSignature.jar" -verify "$SIGNED"
sha256sum "$SIGNED" | tee "$SIGNED.sha256"

echo "signed boot ready: $SIGNED"
