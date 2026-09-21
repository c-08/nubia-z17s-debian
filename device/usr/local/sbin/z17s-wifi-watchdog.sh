#!/bin/sh
# Z17S (NX595J) WiFi 看门狗
# 背景：WCN3990 固件在长时间高负载下可能崩溃（dmesg 出现 "fatal error received ... WLAN RT"），
#       wlan0 会消失且不会自愈，此前只能靠重启恢复。
# 行为：仅在 WiFi 已经断链时动作。默认只做「优雅恢复 + 记日志」，不重启设备。
#       如需恢复失败时自动重启，创建 /etc/z17s-wifi-watchdog.autoreboot 即可。
# 停用：创建 /etc/z17s-wifi-watchdog.disable（或 systemctl disable --now z17s-wifi-watchdog）
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG=/var/log/z17s-wifi-watchdog.log
FAILFILE=/run/z17s-wifi-watchdog.fail
INTERVAL=60
MAX_RESET=3

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

wifi_ok() {
  [ -d /sys/class/net/wlan0 ] || return 1
  iw dev wlan0 link 2>/dev/null | grep -q '^Connected' || return 1
  return 0
}

reset_stack() {
  log "开始优雅恢复：卸载 ath10k"
  modprobe -r ath10k_snoc 2>/dev/null
  modprobe -r ath10k_core 2>/dev/null
  modprobe -r ath 2>/dev/null
  sleep 3

  for rp in /sys/class/remoteproc/remoteproc*; do
    [ -d "$rp" ] || continue
    fw="$(cat "$rp/firmware" 2>/dev/null || true)"
    case "$fw" in
      *mba.mbn|*modem*)
        log "复位 MSS $rp (state=$(cat "$rp/state" 2>/dev/null))"
        echo stop >"$rp/state" 2>/dev/null
        sleep 5
        echo start >"$rp/state" 2>/dev/null
        sleep 14
        ;;
    esac
  done

  modprobe qcom_pd_mapper 2>/dev/null
  systemctl restart z17s-wifi-load.service 2>/dev/null
  sleep 15
  nmcli networking off 2>/dev/null
  sleep 2
  nmcli networking on 2>/dev/null
  sleep 6
}

fails=0
[ -f "$FAILFILE" ] && fails="$(cat "$FAILFILE" 2>/dev/null || echo 0)"
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
log "看门狗启动 (上电前失败计数=$fails)"

while true; do
  if [ -f /etc/z17s-wifi-watchdog.disable ]; then
    sleep 300
    continue
  fi

  # WiFi 无线电被主动关闭（例如用户执行 nmcli radio wifi off）时不干预
  if [ "$(nmcli -t radio wifi 2>/dev/null)" = "disabled" ]; then
    fails=0; echo 0 >"$FAILFILE"
    sleep "$INTERVAL"
    continue
  fi

  if wifi_ok; then
    [ "$fails" -ne 0 ] && log "WiFi 已恢复"
    fails=0; echo 0 >"$FAILFILE"
  else
    fails=$((fails + 1)); echo "$fails" >"$FAILFILE"
    if [ -d /sys/class/net/wlan0 ]; then present=存在; else present=缺失; fi
    log "WiFi 异常（连续第 ${fails} 次）：wlan0=${present}"
    dmesg 2>/dev/null | grep -iE 'ath10k|fatal error received' | tail -4 >>"$LOG"

    if [ "$fails" -le "$MAX_RESET" ]; then
      reset_stack
      if wifi_ok; then
        log "优雅恢复成功"
        fails=0; echo 0 >"$FAILFILE"
      fi
    elif [ -f /etc/z17s-wifi-watchdog.autoreboot ]; then
      log "优雅恢复已失败 $MAX_RESET 次，按 /etc/z17s-wifi-watchdog.autoreboot 要求重启设备"
      sync
      reboot
      sleep 180
    else
      log "优雅恢复已失败 $MAX_RESET 次。设备仍可用（串口/面板正常），如需自动重启请创建 /etc/z17s-wifi-watchdog.autoreboot"
      fails=0; echo 0 >"$FAILFILE"
    fi
  fi

  sleep "$INTERVAL"
done
