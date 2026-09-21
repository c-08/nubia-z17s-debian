#!/bin/sh
# z17s-netfallback.sh -- make the phone reach the internet through the PC over the USB
# link WITHOUT Windows ICS (i.e. without administrator rights on the PC).
#
#   sh z17s-netfallback.sh on      # route the docker daemon through the PC proxy
#   sh z17s-netfallback.sh off     # take that back out
#   sh z17s-netfallback.sh status  # show what is in effect
#
# Scope (deliberately small)
#   ONLY /etc/docker/daemon.json is touched.  Name resolution is NOT handled here any
#   more: usb0 is a NetworkManager connection (profile "z17s-usb0") carrying
#   ipv4.dns 192.168.137.1, so NM writes and maintains /etc/resolv.conf itself and the
#   PC side resolver is always in the list.  Hand-editing resolv.conf used to fight NM
#   and every link change wiped it -- do not go back to that.
#
#   Note this only covers the docker *daemon* (i.e. image pulls).  Traffic from inside a
#   container (qinglong cloning scripts, npm/pip) is NOT proxied by this; for that you
#   want ICS, which gives the phone a real transparent NAT.  Use flash\setup-rndis.cmd on
#   the PC for that, and then run `z17s-netfallback.sh off` here.
#
# Requirements on the PC: flash\start-proxy.cmd must be running (HTTP proxy tcp/3128 and
# DNS relay udp/53 on 0.0.0.0).

set -u

USB_IP=192.168.137.1
PROXY="http://${USB_IP}:3128"
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_JSON_BAK=/etc/docker/daemon.json.z17s-bak

usage() { echo "usage: $0 {on|off|status}"; exit 2; }
[ $# -eq 1 ] || usage

case "$1" in
  on)
    echo "=== docker daemon proxy ==="
    [ -f "$DAEMON_JSON" ] && [ ! -f "$DAEMON_JSON_BAK" ] && cp -a "$DAEMON_JSON" "$DAEMON_JSON_BAK"
    cat > "$DAEMON_JSON" <<EOF
{
  "proxies": {
    "http-proxy": "${PROXY}",
    "https-proxy": "${PROXY}",
    "no-proxy": "localhost,127.0.0.1,::1,192.168.137.0/24,192.168.1.0/24"
  }
}
EOF
    cat "$DAEMON_JSON"
    echo "=== restart docker ==="
    systemctl restart docker
    sleep 5
    echo "docker: $(systemctl is-active docker)"
    docker info 2>/dev/null | grep -iE "HTTP Proxy|HTTPS Proxy" || echo "  (proxies not reported yet)"
    echo "FALLBACK_ON"
    ;;

  off)
    echo "=== docker ==="
    # NOTE: a "backup" that is itself one of our generated files is not a backup.  The
    # earlier version restored from it and therefore never actually turned the proxy off
    # (the file contents were identical).  Only restore a backup that does NOT mention
    # the PC side.
    if [ -f "$DAEMON_JSON_BAK" ] && ! grep -q '192\.168\.137\.1' "$DAEMON_JSON_BAK"; then
        cp -a "$DAEMON_JSON_BAK" "$DAEMON_JSON"
        echo "    restored daemon.json from backup"
    else
        rm -f "$DAEMON_JSON"
        echo "    removed daemon.json (no genuine pre-existing config to restore)"
    fi
    rm -f "$DAEMON_JSON_BAK"
    systemctl restart docker
    sleep 5
    echo "docker: $(systemctl is-active docker)"
    echo "    proxy entries in docker info: $(docker info 2>/dev/null | grep -ciE 'HTTP Proxy')  (0 = off)"
    echo "FALLBACK_OFF"
    ;;

  status)
    echo "--- daemon.json ---"; cat "$DAEMON_JSON" 2>/dev/null || echo "(not present)"
    echo "--- docker proxies ---"; docker info 2>/dev/null | grep -iE "HTTP Proxy|HTTPS Proxy" || echo "none"
    echo "--- usb0 (NetworkManager) ---"; nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null | grep usb0
    ip -br addr show usb0 2>/dev/null
    echo "--- resolv.conf ---"; cat /etc/resolv.conf
    echo "--- DNS ---"; getent hosts github.com | head -1 || echo "  DNS FAILED"
    echo "--- proxy reachability ---"
    curl -s -m 6 -x "$PROXY" -o /dev/null -w "  http_code=%{http_code}\n" https://mirrors.aliyun.com/ 2>&1
    echo "--- transparent path (needs ICS) ---"
    curl -s -m 6 -o /dev/null -w "  direct_http_code=%{http_code}   (000 = no ICS: use the proxy)\n" https://mirrors.aliyun.com/ 2>&1
    echo "FALLBACK_STATUS"
    ;;

  *) usage ;;
esac
