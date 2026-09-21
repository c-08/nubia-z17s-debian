#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/common.sh"

for cmd in depmod mke2fs rsync sha256sum sudo tar truncate useradd usermod; do
	need_cmd "$cmd"
done

BASE_TARBALL_ASSET="$ASSETS_DIR/rootfs/trixie-arm64-rootfs.tar.zst"
BASE_TARBALL="$BASE_TARBALL_ASSET"
DRIVER_BUNDLE="$BUILD_DIR/driver-bundle"
WORK_ROOT="${WORK_ROOT:-$HOME/.cache/z17s-debian-build}"
ROOTFS="$WORK_ROOT/rootfs"
NATIVE_IMAGE="$WORK_ROOT/rootfs-6.12-userdata-debian13.ext4"
OUTPUT="$BUILD_DIR/rootfs-6.12-userdata-debian13.ext4"
SIZE_MB="${SIZE_MB:-4096}"
PASSWORD_HASH="${Z17S_PASSWORD_HASH:-!}"

prepare_build_dir
if [[ ! -f "$BASE_TARBALL" ]]; then
	BASE_TARBALL="$BUILD_DIR/trixie-arm64-rootfs.tar.zst"
	parts=("$BASE_TARBALL_ASSET".part-00 "$BASE_TARBALL_ASSET".part-01 \
		"$BASE_TARBALL_ASSET".part-02)
	for part in "${parts[@]}"; do
		need_file "$part"
	done
	cat "${parts[@]}" > "$BASE_TARBALL.tmp"
	mv -f "$BASE_TARBALL.tmp" "$BASE_TARBALL"
	(cd "$BUILD_DIR" && sha256sum --check \
		"$ASSETS_DIR/rootfs/trixie-arm64-rootfs.tar.zst.sha256")
fi
need_dir "$DRIVER_BUNDLE/lib/modules/$KVER_EXPECTED"
need_dir "$DRIVER_BUNDLE/lib/firmware"
[[ "$WORK_ROOT" == "$HOME/.cache/z17s-debian-"* ]] || \
	die "WORK_ROOT must stay below $HOME/.cache/z17s-debian-*"

echo "== extract frozen Debian 13 arm64 base =="
sudo rm -rf "$ROOTFS"
sudo mkdir -p "$ROOTFS"
sudo tar --numeric-owner -xaf "$BASE_TARBALL" -C "$ROOTFS"

echo "== install overlay, rebuilt modules, firmware and device tools =="
sudo rsync -a "$BUNDLE_ROOT/overlay/" "$ROOTFS/"
sudo rsync -a "$DRIVER_BUNDLE/lib/" "$ROOTFS/lib/"
sudo rsync -a "$DRIVER_BUNDLE/usr/" "$ROOTFS/usr/"
sudo find "$ROOTFS/lib/modules/$KVER_EXPECTED" -type f -name 'ipa.ko*' -delete
sudo depmod -b "$ROOTFS" "$KVER_EXPECTED"

groups=()
for group in sudo audio video render input netdev; do
	grep -q "^${group}:" "$ROOTFS/etc/group" && groups+=("$group")
done
GROUPS_CSV="$(IFS=,; echo "${groups[*]}")"
if grep -q '^z17s:' "$ROOTFS/etc/passwd"; then
	sudo usermod --prefix "$ROOTFS" --password "$PASSWORD_HASH" \
		--shell /bin/bash --groups "$GROUPS_CSV" --append z17s
else
	sudo useradd --prefix "$ROOTFS" --uid 1000 --user-group --create-home \
		--home-dir /home/z17s --shell /bin/bash --comment 'Z17S user' \
		--groups "$GROUPS_CSV" --password "$PASSWORD_HASH" z17s
fi

echo nx595j-debian13 | sudo tee "$ROOTFS/etc/hostname" >/dev/null
sudo tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost nx595j-debian13
::1       localhost ip6-localhost ip6-loopback
EOF
sudo tee "$ROOTFS/etc/network/interfaces" >/dev/null <<'EOF'
auto lo
iface lo inet loopback
EOF
sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<'EOF'
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://security.debian.org/debian-security trixie-security main
EOF
sudo truncate -s 0 "$ROOTFS/etc/machine-id"

echo "== enable verified service order =="
sudo mkdir -p \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants" \
	"$ROOTFS/etc/systemd/system/getty.target.wants"
sudo ln -sfn ../z17s-early.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/z17s-early.service"
sudo ln -sfn ../z17s-grow-rootfs.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/z17s-grow-rootfs.service"
sudo ln -sfn ../z17s-audio-load.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/z17s-audio-load.service"
sudo ln -sfn ../z17s-wifi-load.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/z17s-wifi-load.service"
sudo ln -sfn /lib/systemd/system/NetworkManager.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
sudo ln -sfn /lib/systemd/system/bluetooth.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/bluetooth.service"
sudo ln -sfn /lib/systemd/system/serial-getty@.service \
	"$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
for unit in qrtr-ns.service rmtfs.service tqftpserv.service; do
	sudo ln -sfn /dev/null "$ROOTFS/etc/systemd/system/$unit"
done

sudo find "$ROOTFS/etc/NetworkManager" -type d -exec chmod 0755 {} +
sudo find "$ROOTFS/etc/NetworkManager" -type f -exec chmod 0644 {} +
sudo find "$ROOTFS/lib/modules/$KVER_EXPECTED" "$ROOTFS/lib/firmware" \
	-type d -exec chmod 0755 {} +
sudo find "$ROOTFS/lib/modules/$KVER_EXPECTED" "$ROOTFS/lib/firmware" \
	-type f -exec chmod 0644 {} +
sudo find "$ROOTFS/usr/local/sbin" -type f -name 'z17s-*.sh' \
	-exec chmod 0755 {} +
sudo chown -R 0:0 \
	"$ROOTFS/etc/NetworkManager" \
	"$ROOTFS/etc/modprobe.d" \
	"$ROOTFS/etc/systemd/system" \
	"$ROOTFS/lib/modules/$KVER_EXPECTED" \
	"$ROOTFS/lib/firmware" \
	"$ROOTFS/usr/local/sbin"

required=(
	usr/bin/nmtui
	usr/bin/rmtfs
	usr/bin/tqftpserv
	usr/sbin/ip
	usr/sbin/iw
	usr/sbin/NetworkManager
	usr/local/sbin/z17s-wifi-load.sh
	usr/local/sbin/z17s-audio-load.sh
	lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
	lib/firmware/qca/crbtfw21.tlv
	lib/firmware/qcom/msm8998/nubia/adsp.mdt
	lib/firmware/tas2555_uCDSP.bin
	lib/firmware/tas2555_cal.bin
	lib/modules/$KVER_EXPECTED/kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko
	lib/modules/$KVER_EXPECTED/kernel/drivers/gpu/drm/msm/msm.ko
	lib/modules/$KVER_EXPECTED/kernel/sound/soc/codecs/snd-soc-tas2555.ko
)
for path in "${required[@]}"; do
	[[ -e "$ROOTFS/$path" ]] || die "rootfs missing: /$path"
done
if find "$ROOTFS/lib/modules/$KVER_EXPECTED" -name 'ipa.ko*' | grep -q .; then
	die "unsafe ipa.ko must not be installed"
fi

echo "== create ${SIZE_MB} MiB ext4 userdata image =="
mkdir -p "$WORK_ROOT" "$BUILD_DIR"
rm -f "$NATIVE_IMAGE"
truncate -s "${SIZE_MB}M" "$NATIVE_IMAGE"
sudo mke2fs -t ext4 -L z17s-debian13 -F -d "$ROOTFS" "$NATIVE_IMAGE"
sudo chown "$(id -u):$(id -g)" "$NATIVE_IMAGE"
cp -f "$NATIVE_IMAGE" "$OUTPUT"
sha256sum "$OUTPUT" | tee "$OUTPUT.sha256"

echo "rootfs ready: $OUTPUT"
echo "note: user z17s is locked unless Z17S_PASSWORD_HASH was supplied"
