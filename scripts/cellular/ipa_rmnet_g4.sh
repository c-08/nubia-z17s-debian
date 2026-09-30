#!/bin/sh
# ---------------------------------------------------------------------------
# Z17S  G4-RMNET —— 在 rmnet_ipa0 上叠 rmnet(QMAP) 设备，再配 IP 发真实 ICMP
#
# 依据：主线 ipa_modem.c 中 header_ops=NULL / ARPHRD_RAWIP /
#       needed_headroom=sizeof(rmnet_map_header) / "endpoint is configured for QMAP"
#       => rmnet_ipa0 是 QMAP 中间层，L3 必须挂到 rmnet vnd 上。
#
# 前提：qmi_up.py 仍 hold（PDP 已建立，mux_id=0 已 bind）
# 安全：只加 /32 主机路由，不动默认路由（ssh 走 usb0）
# ---------------------------------------------------------------------------
LOG=/root/ipa_rmnet_g4.log
QLOG=/root/g3-qmi-warm.log
K=/dev/kmsg
say() { printf '<3>Z17SRMNET[%s] %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" > $K 2>/dev/null; sync; }

int2ip() { echo "$1" | awk '{printf "%d.%d.%d.%d\n", int($1/16777216)%256, int($1/65536)%256, int($1/256)%256, $1%256}'; }
pfxlen()  { echo "$1" | awk '{n=$1;c=0;ok=1;for(i=31;i>=0;i--){b=int(n/(2^i))%2;if(b==1&&ok)c++;else ok=0}print c}'; }

exec >>"$LOG" 2>&1

A_INT=$(grep -a "wds.settings.ipv4_address" "$QLOG" | head -1 | grep -o '[0-9]*$')
G_INT=$(grep -a "wds.settings.ipv4_gateway_address" "$QLOG" | head -1 | grep -o '[0-9]*$')
M_INT=$(grep -a "wds.settings.ipv4_gateway_subnet_mask" "$QLOG" | head -1 | grep -o '[0-9]*$')
D1_INT=$(grep -a "wds.settings.primary_ipv4_dns_address" "$QLOG" | head -1 | grep -o '[0-9]*$')
D2_INT=$(grep -a "wds.settings.secondary_ipv4_dns_address" "$QLOG" | head -1 | grep -o '[0-9]*$')

A=$(int2ip "$A_INT"); G=$(int2ip "$G_INT"); D1=$(int2ip "$D1_INT"); D2=$(int2ip "$D2_INT")
PFX=$(pfxlen "$M_INT"); [ -n "$PFX" ] && [ "$PFX" != "0" ] || PFX=30

echo "============ Z17S G4-RMNET  $(date +%F' '%T) ============"
echo "boot_id  = $(cat /proc/sys/kernel/random/boot_id)"
echo "uptime   = $(cut -d' ' -f1 /proc/uptime)s"
echo "qmi hold = $(pgrep -af '[q]mi_up.py' | head -1)"
echo "pm       = $(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status) delay=$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms)"
echo "carrier  = A=$A/$PFX  GW=$G  DNS=$D1 / $D2   (profile modem_def_prof)"
say "RMNET begin A=$A/$PFX GW=$G"

# 先清掉直接挂在 rmnet_ipa0 上的地址（无效配置）
ip addr flush dev rmnet_ipa0 2>/dev/null
for D in "$G" "$D1" "$D2" 120.80.80.80 221.5.88.88 223.5.5.5 114.114.114.114; do
	[ -n "$D" ] && ip route del "$D"/32 2>/dev/null
done

echo
echo "--- [1] modprobe rmnet ---"
modprobe rmnet; echo "### rc=$?  lsmod: $(lsmod | grep -c '^rmnet')"
say "RMNET modprobe rc=$?"

echo
echo "--- [2] ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 ---"
ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0; echo "### rc=$?"
say "RMNET link-add rc=$?"
if ! ip link show rmnet0 >/dev/null 2>&1; then
	echo "!!! rmnet0 创建失败，放弃"
	say "RMNET link-add FAILED"
	echo "============ END (link-add failed) $(date +%F' '%T) ============"
	exit 1
fi
ip -d -o link show rmnet0

echo
echo "--- [3] ip link set rmnet0 up ---"
ip link set rmnet0 up; echo "### rc=$?"
say "RMNET link-up rc=$?"
ip -d -o link show rmnet0

echo
echo "--- [4] ip addr add $A/$PFX dev rmnet0 ---"
ip addr add "$A/$PFX" dev rmnet0; echo "### rc=$?"
say "RMNET addr rc=$?"
ip -o -4 addr show rmnet0

echo
echo "--- [5] /32 路由（经 rmnet0）---"
ip route add "$G"/32 dev rmnet0 2>&1; echo "### gw/32 rc=$?"
for D in "$D1" "$D2" 120.80.80.80 221.5.88.88 223.5.5.5 114.114.114.114; do
	[ -z "$D" ] && continue
	ip route add "$D"/32 via "$G" dev rmnet0 2>&1; echo "### $D/32 rc=$?"
done
say "RMNET routes added"
ip route show dev rmnet0
echo "default routes (必须仍是 usb0):"; ip -o route show default

echo
echo "=========== P1: ping -c3 -W5 gateway $G (经 rmnet0) ==========="
ping -c 3 -W 5 -I rmnet0 "$G"; echo "### ping-gw rc=$?"
say "RMNET ping-gw rc=$?"
ip neigh show dev rmnet0

echo
echo "=========== P2: ping -c3 -W5 $D1 (联通 DNS) ==========="
ping -c 3 -W 5 -I rmnet0 "$D1"; echo "### ping-dns rc=$?"
say "RMNET ping-dns rc=$?"

echo
echo "=========== P3: ping -c3 -W5 223.5.5.5 ==========="
ping -c 3 -W 5 -I rmnet0 223.5.5.5; echo "### ping-public rc=$?"
say "RMNET ping-public rc=$?"

echo
echo "=========== P4: ping -c3 -W5 114.114.114.114 ==========="
ping -c 3 -W 5 -I rmnet0 114.114.114.114; echo "### ping-114 rc=$?"
say "RMNET ping-114 rc=$?"

echo
echo "--- rmnet0 stats ---"; ip -s link show rmnet0
echo "--- rmnet_ipa0 stats ---"; ip -s link show rmnet_ipa0
echo "--- neigh ---"; ip neigh show
echo "--- Z17SIPA tail ---"; dmesg | grep -a Z17SIPA | tail -8
echo "============ END  $(date +%F' '%T) ============"
say "RMNET END"
