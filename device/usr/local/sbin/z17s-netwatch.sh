#!/bin/sh
# z17s-netwatch.sh -- keep the Z17S online by preferring the USB RNDIS link whenever the
# WiFi default gateway stops answering.
#
# The ath10k/WCN3990 firmware can assert and leave wlan0 "up" while silently dropping all
# traffic, so the kernel will NOT fail over on its own (its default route stays in place).
# This script probes both gateways and flips the USB route metric accordingly:
#     wifi broken -> USB default metric 50   (USB wins)
#     wifi fine   -> USB default metric 1000 (wifi stays primary, USB is the backup)
set -u

LOG=/var/log/z17s-netwatch.log
USB_GW=192.168.137.1
USB_METRIC_FAIL=50
USB_METRIC_OK=1000

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; logger -t z17s-netwatch "$*" 2>/dev/null; }

[ -e /sys/class/net/usb0 ] || exit 0

wifi_gw="$(ip route show default dev wlan0 2>/dev/null | awk '{print $3; exit}')"
wifi_ok=0
if [ -n "${wifi_gw:-}" ]; then
    ping -c 1 -W 2 -I wlan0 "$wifi_gw" >/dev/null 2>&1 && wifi_ok=1
fi

usb_ok=0
ping -c 1 -W 2 -I usb0 "$USB_GW" >/dev/null 2>&1 && usb_ok=1

cur="$(ip route show default dev usb0 2>/dev/null | sed -n 's/.*metric \([0-9][0-9]*\).*/\1/p')"
[ -z "$cur" ] && ip route replace default via "$USB_GW" dev usb0 metric "$USB_METRIC_OK" 2>/dev/null

if [ "$usb_ok" = 1 ] && [ "$wifi_ok" = 0 ]; then
    want=$USB_METRIC_FAIL
else
    want=$USB_METRIC_OK
fi

if [ "${cur:-}" != "$want" ]; then
    ip route replace default via "$USB_GW" dev usb0 metric "$want" 2>/dev/null
    log "wifi_ok=$wifi_ok usb_ok=$usb_ok -> usb default metric $cur => $want"
    if [ "$want" = "$USB_METRIC_FAIL" ]; then
        # NetworkManager only regenerates resolv.conf on link changes, so write one now.
        printf '# z17s-netwatch: wifi gateway unreachable, DNS via USB RNDIS (PC ICS)\nnameserver 192.168.137.1\n' > /etc/resolv.conf
        log "resolv.conf switched to 192.168.137.1"
    fi
fi

exit 0
