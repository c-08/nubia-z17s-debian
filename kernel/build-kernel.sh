#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/common.sh"

need_cmd make
need_cmd aarch64-linux-gnu-gcc
need_cmd rsync
need_cmd depmod

KERNEL="$(kernel_dir "${1:-}")"
KOUT="$BUILD_DIR/kernel-out"
MODROOT="$BUILD_DIR/driver-bundle"
JOBS="${JOBS:-$(nproc)}"

assert_build_target "$KOUT"
assert_build_target "$MODROOT"
mkdir -p "$KOUT" "$MODROOT"

make -C "$KERNEL" O="$KOUT" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- z17s_defconfig

CONFIG="$KOUT/.config"
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_NFT_COMPAT
"$KERNEL/scripts/config" --file "$CONFIG" --enable CONFIG_QCOM_SPMI_RRADC
"$KERNEL/scripts/config" --file "$CONFIG" --enable CONFIG_CHARGER_QCOM_SMB2
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SND_SOC_QDSP6
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SND_SOC_MSM8998
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SLIMBUS
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SLIM_QCOM_NGD_CTRL
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_REGMAP_SLIMBUS
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SND_SOC_WCD9335
"$KERNEL/scripts/config" --file "$CONFIG" --module CONFIG_SND_SOC_TAS2555

make -C "$KERNEL" O="$KOUT" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null
make -C "$KERNEL" O="$KOUT" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" \
	Image.gz modules qcom/msm8998-nubia-nx595j.dtb

KVER="$(make -s -C "$KERNEL" O="$KOUT" ARCH=arm64 kernelrelease)"
[[ "$KVER" == "$KVER_EXPECTED" ]] || \
	die "kernel release is $KVER; expected $KVER_EXPECTED"

rm -rf "$MODROOT/lib/modules"
make -C "$KERNEL" O="$KOUT" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- \
	INSTALL_MOD_PATH="$MODROOT" modules_install

# Loading IPA on this device caused a repeatable boot loop. Keep the source
# buildable, but never install the module in the bootable Debian image.
find "$MODROOT/lib/modules/$KVER" -type f -name 'ipa.ko*' -delete
depmod -b "$MODROOT" "$KVER"

mkdir -p "$MODROOT/lib"
rsync -a --delete "$ASSETS_DIR/driver-bundle/lib/firmware/" \
	"$MODROOT/lib/firmware/"
rsync -a --delete "$ASSETS_DIR/driver-bundle/usr/" "$MODROOT/usr/"

cp -f "$KOUT/arch/arm64/boot/Image.gz" "$BUILD_DIR/Image.gz-$KVER"
cp -f "$KOUT/arch/arm64/boot/dts/qcom/msm8998-nubia-nx595j.dtb" \
	"$BUILD_DIR/msm8998-nubia-nx595j-base.dtb"
cp -f "$CONFIG" "$BUILD_DIR/config-$KVER"

DTCDIR="$KOUT/scripts/dtc"
need_file "$DTCDIR/dtc"
need_file "$DTCDIR/fdtoverlay"
overlay_bins=()
for src in \
	"$BUNDLE_ROOT/dts/overlays/msm8998-nubia-nx595j-audio-tas2555-probe-v12.dtso" \
	"$BUNDLE_ROOT/dts/overlays/msm8998-nubia-nx595j-audio-tas2555-speaker-v12p1.dtso" \
	"$BUNDLE_ROOT/dts/overlays/msm8998-nubia-nx595j-charge-basic-v14.dtso"
do
	out="$BUILD_DIR/$(basename "${src%.dtso}").dtbo"
	"$DTCDIR/dtc" -@ -I dts -O dtb -o "$out" "$src"
	overlay_bins+=("$out")
done

"$DTCDIR/fdtoverlay" \
	-i "$BUILD_DIR/msm8998-nubia-nx595j-base.dtb" \
	-o "$BUILD_DIR/msm8998-nubia-nx595j.dtb" \
	"${overlay_bins[@]}"

for required in \
	drivers/net/wireless/ath/ath10k/ath10k_snoc.ko \
	drivers/gpu/drm/msm/msm.ko \
	drivers/bluetooth/hci_uart.ko \
	drivers/input/rmi4/rmi_i2c.ko \
	sound/soc/codecs/snd-soc-wcd9335.ko \
	sound/soc/codecs/snd-soc-tas2555.ko \
	sound/soc/qcom/snd-soc-msm8998.ko
do
	need_file "$MODROOT/lib/modules/$KVER/kernel/$required"
done

sha256sum \
	"$BUILD_DIR/Image.gz-$KVER" \
	"$BUILD_DIR/msm8998-nubia-nx595j.dtb" \
	"$BUILD_DIR/config-$KVER" > "$BUILD_DIR/kernel-SHA256SUMS.txt"

echo "kernel ready: $BUILD_DIR/Image.gz-$KVER"
echo "DTB ready:    $BUILD_DIR/msm8998-nubia-nx595j.dtb"
echo "modules:      $MODROOT/lib/modules/$KVER"
