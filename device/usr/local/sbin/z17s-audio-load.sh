#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "z17s-audio-load: $*" | tee /dev/kmsg; }
load() {
  modprobe "$1" >>/var/log/z17s-audio-load.log 2>&1 || {
    log "module failed: $1"
    return 1
  }
}

: >/var/log/z17s-audio-load.log
load qcom_hwspinlock
load smp2p
load qrtr
load qrtr_smd
load qcom_pd_mapper

# SLIM NGD must observe LPASS starting, so register it before ADSP remoteproc.
load slim_qcom_ngd_ctrl
load snd_soc_wcd9335
load qcom_q6v5_pas

adsp=
for count in $(seq 1 120); do
  for rp in /sys/class/remoteproc/remoteproc*; do
    [ -d "$rp" ] || continue
    fw="$(cat "$rp/firmware" 2>/dev/null || true)"
    case "$fw" in
      *adsp*) adsp="$rp" ;;
    esac
  done
  [ -n "$adsp" ] && break
  sleep 0.1
done
[ -n "$adsp" ] || { log "ADSP remoteproc missing"; exit 1; }
state="$(cat "$adsp/state" 2>/dev/null || true)"
if [ "$state" != running ]; then
  echo start >"$adsp/state"
fi

for count in $(seq 1 120); do
  [ "$(cat "$adsp/state" 2>/dev/null || true)" = running ] && break
  sleep 0.1
done
[ "$(cat "$adsp/state" 2>/dev/null || true)" = running ] || {
  log "ADSP did not reach running"
  exit 1
}

for count in $(seq 1 120); do
  [ -L /sys/bus/slimbus/devices/217:1a0:1:0/driver ] && break
  sleep 0.1
done
[ -L /sys/bus/slimbus/devices/217:1a0:1:0/driver ] || {
  log "WCD9335 SLIM device did not bind"
  exit 1
}

load apr
load q6core
load q6afe
load q6afe_dai
load q6afe_clocks
load q6adm
load q6routing
load q6asm
load q6asm_dai
load snd_soc_tas2555

# TAS2555 uses request_firmware_nowait(). modprobe returns while the program is
# still being written over I2C; probing the machine card at that point races
# the codec callback and leaves checksum/failsafe bits latched.
sleep 2
load snd_soc_msm8998

for count in $(seq 1 100); do
  [ -d /sys/class/sound/card0 ] && break
  sleep 0.1
done
[ -d /sys/class/sound/card0 ] || {
  log "ALSA card missing"
  exit 1
}
log "ready card=$(cat /sys/class/sound/card0/id 2>/dev/null) adsp=$(basename "$adsp")"
