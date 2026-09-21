#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "z17s-wifi-load: $*" | tee /dev/kmsg; }
start_once() {
  name="$1"
  shift
  if pgrep -x "$name" >/dev/null 2>&1; then
    return 0
  fi
  "$@" >/var/log/"$name".log 2>&1 &
}

[ -d /sys/class/net/wlan0 ] && { log "wlan0 already present"; exit 0; }

for module in qcom_hwspinlock smp2p qrtr qrtr-smd led-class mdt_loader \
  rmtfs_mem qcom_q6v5_mss; do
  modprobe "$module" 2>/dev/null || true
done
sleep 1

mss=
for rp in /sys/class/remoteproc/remoteproc*; do
  [ -d "$rp" ] || continue
  fw="$(cat "$rp/firmware" 2>/dev/null || true)"
  case "$fw" in
    *mba.mbn|*modem*) mss="$rp" ;;
  esac
done
[ -n "$mss" ] || { log "MSS remoteproc missing"; exit 1; }
state="$(cat "$mss/state" 2>/dev/null || true)"
[ "$state" = running ] || echo start >"$mss/state"
sleep 8

start_once diag-router /usr/bin/diag-router
start_once rmtfs /usr/bin/rmtfs -r -P -s
start_once tqftpserv /usr/bin/tqftpserv
sleep 3
modprobe qcom_pd_mapper 2>/dev/null || start_once pd-mapper /usr/bin/pd-mapper
sleep 3

for module in libaes aes_generic aes-ce-cipher aes-ce-blk aes-ce-ccm ccm ctr \
  cmac gf128mul ghash-generic crypto_null gcm ath ath10k_core ath10k_snoc; do
  modprobe "$module" 2>/dev/null || true
done
sleep 8

[ -d /sys/class/net/wlan0 ] || {
  dmesg | grep -iE 'ath10k|wlfw|wlan|bdf' | tail -n 80 \
    >/var/log/z17s-wifi-load-dmesg.txt || true
  log "wlan0 missing"
  exit 1
}

if ! mountpoint -q /mnt/persist; then
  persist=/dev/disk/by-partlabel/persist
  [ -b "$persist" ] || persist=/dev/sda2
  mount -o ro -t ext4 "$persist" /mnt/persist 2>/dev/null || true
fi
mac_hex="$(sed -n 's/^Intf0MacAddress=//p' /mnt/persist/wlan_mac.bin 2>/dev/null \
  | head -n 1 | tr -d '\r\n ' || true)"
if [ "${#mac_hex}" -eq 12 ]; then
  mac="$(echo "$mac_hex" | sed 's/../&:/g;s/:$//' | tr 'A-F' 'a-f')"
  ip link set wlan0 address "$mac" 2>/dev/null || true
fi
ip link set wlan0 up
iw dev wlan0 set power_save off 2>/dev/null || true
log "wlan0 ready $(cat /sys/class/net/wlan0/address)"
