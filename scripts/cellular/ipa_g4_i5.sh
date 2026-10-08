#!/bin/sh
# ---------------------------------------------------------------------------
# Z17S  G4 / pass-4 —— 关键新单变量：insmod 后重启 modem
#
# 上一轮根因（已定位）：insmod ipa 时 modem 早已在跑，IPA 初始化当着 modem 的面
# 重配硬件 => modem 固件断言崩溃（ipa_sio.c:2107 ipa_ipfltr.init_done == TRUE failed）
# => rmnet_ipa0 永远不会被创建。
#
# 本轮新单变量：IPA 就位之后，把 modem 重新拉起来（remoteproc0 stop/start），
# 让 modem 在一个 "IPA 已就位" 的世界里启动。
#
# 已修的三坑：
#   1) ping 不再走管道（假阳性）
#   2) insmod 后轮询 rmnet_ipa0 出现
#   3) pgrep 改用 ps -eo args 精确匹配（不自匹配 ssh）
#
# 安全：全程不 `ip link set rmnet_ipa0 down`、不 rmmod（modem 崩后 rmmod 会 SRCU 死锁）
# ---------------------------------------------------------------------------
LOG=/root/ipa_g4_i5.log
QMI=/root/g3-qmi-i5.log
K=/dev/kmsg
say() { printf '<3>Z17SI5[%s] %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" > $K 2>/dev/null; }
ieob()  { dmesg | grep -ac 'isr_ieob'; }
crashed() { dmesg | grep -ac 'fatal error received'; }
qmi_alive() { [ "$(ps -eo args | grep -c '^python3 /root/qmi_up2.py')" -ge 1 ]; }
int2ip() { echo "$1" | awk '{printf "%d.%d.%d.%d\n", int($1/16777216)%256, int($1/65536)%256, int($1/256)%256, $1%256}'; }
pfxlen() { echo "$1" | awk '{n=$1;c=0;ok=1;for(i=31;i>=0;i--){b=int(n/(2^i))%2;if(b==1&&ok)c++;else ok=0}print c}'; }

exec >>"$LOG" 2>&1
echo "============ Z17S G4 / PASS4 modem-restart-after-insmod  $(date +%F' '%T) ============"
echo "boot_id = $(cat /proc/sys/kernel/random/boot_id)  uptime=$(cut -d' ' -f1 /proc/uptime)s"
echo "modem state(前) = $(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"
say "I5 begin"

# ================================================================ [1] modem online
echo
echo "--- [1] modem online ---"
qmicli -d qrtr://0 --dms-set-operating-mode=online 2>&1 | head -1
sleep 8
qmicli -d qrtr://0 --nas-get-serving-system 2>&1 | grep -iE "registration state|description" | head -2
echo "QRTR node0 服务数(前) = $(python3 /root/qrtr_services.py 2>/dev/null | grep -A1 'node 0' | tail -1)"
say "I5 modem-online"

# ================================================================ [2] insmod IPA
echo
echo "--- [2] insmod /root/ipa-instr3.ko（先不设 seq/rep，用现表值）---"
insmod /root/ipa-instr3.ko 2>&1; echo "### rc=$?"
say "I5 insmod rc=$?"
# 等 probe 走完
for i in $(seq 1 20); do
	dmesg | grep -q "IPA driver setup completed successfully" && { echo ">>> probe 完成（约 $((i*2))s）"; break; }
	sleep 2
done
dmesg | grep -aE "IPA driver setup|Runtime PM usage" | tail -2

# ================================================================ [3] pin autosuspend
echo
echo "--- [3] pin autosuspend = -1 ---"
echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms 2>&1
printf 'control=%s delay=%s status=%s\n' \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/control)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)"
say "I5 pinned"

# ================================================================ [4] ★ 重启 modem
echo
echo "--- [4] ★ 重启 modem（remoteproc0 stop -> start）---"
echo "state(前) = $(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"
echo stop  > /sys/class/remoteproc/remoteproc0/state 2>&1; echo "### stop rc=$?"
sleep 5
echo "state(停) = $(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"
echo start > /sys/class/remoteproc/remoteproc0/state 2>&1; echo "### start rc=$?"
say "I5 modem-restarted"

# ================================================================ [5] 等握手 + 网卡
echo
echo "--- [5] 等 rmnet_ipa0 出现（≤90s）---"
GOT=""
for i in $(seq 1 45); do
	if ip link show rmnet_ipa0 >/dev/null 2>&1; then GOT="yes"; echo ">>> rmnet_ipa0 出现（约 $((i*2))s）"; break; fi
	if [ "$(crashed)" -gt 0 ]; then echo "!!! modem 又崩了（crashed=$(crashed)）"; break; fi
	sleep 2
done
[ -n "$GOT" ] || echo "(90s 内未出现)"
ip -br link show | grep -E "rmnet|ipa" || echo "(无网卡)"
dmesg | grep -aiE "IPA modem start|Assert|fatal error|received modem" | tail -6
say "I5 handshake got=[$GOT]"

# ================================================================ [6] 起 PDP
echo
echo "--- [6] 起 PDP（qmi_up2.py，hold 3600）---"
rm -f "$QMI"
setsid python3 /root/qmi_up2.py 3gnet 3 16 1 0 3600 > "$QMI" 2>&1 &
sleep 18
grep -aE "START_NETWORK|CARRIER|FAIL|rc=" "$QMI" | tail -10
qmi_alive && echo "qmi 进程存活 ✅" || echo "qmi 进程没了 ❌"

A_INT=$(grep -a "ipv4_address" "$QMI" | head -1 | grep -o '[0-9]*$')
G_INT=$(grep -a "ipv4_gateway_address" "$QMI" | head -1 | grep -o '[0-9]*$')
M_INT=$(grep -a "ipv4_gateway_subnet_mask" "$QMI" | head -1 | grep -o '[0-9]*$')
A=$(int2ip "$A_INT"); G=$(int2ip "$G_INT"); PFX=$(pfxlen "$M_INT")
[ -n "$PFX" ] && [ "$PFX" != "0" ] || PFX=30
echo ">>> 解析 A=$A/$PFX GW=$G"
say "I5 pdp A=$A/$PFX GW=$G"

# ================================================================ [7] link up + rmnet0 + L3
if [ -n "$GOT" ] && [ "$A" != "0.0.0.0" ]; then
	echo
	echo "--- [7] link up + rmnet0 + L3 ---"
	ip link set rmnet_ipa0 up 2>&1; echo "### linkup rc=$?"
	say "I5 linkup rc=$?"
	modprobe rmnet 2>/dev/null
	ip link del rmnet0 2>/dev/null
	ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 2>&1; echo "### link-add rc=$?"
	ip link set rmnet0 up 2>&1
	ip addr add "$A/$PFX" dev rmnet0 2>&1; echo "### addr rc=$?"
	ip route add "$G"/32 dev rmnet0 2>&1; echo "### route rc=$?"
	ip -o -4 addr show rmnet0

	# ============================================================ [8] ping（不接管道）
	echo
	echo "=========== [8] ping -c 4 -W 2 via rmnet0 -> $G ==========="
	P0=$(ieob)
	say "I5 ping start ieob=$P0"
	ping -c 4 -W 2 -I rmnet0 "$G" > /root/ping-i5.out 2>&1
	PRC=$?
	cat /root/ping-i5.out | tail -4
	P1=$(ieob)
	echo "### ping rc=$PRC  isr_ieob $P0 -> $P1"
	say "I5 ping done rc=$PRC ieob=$P1"

	# ============================================================ [9] 读数
	echo
	echo "=========== [9] 读数 ==========="
	printf 'isr_ieob=%s trans_COMPLETE=%s\n' "$(ieob)" "$(dmesg | grep -ac 'trans_COMPLETE')"
	printf 'tre_reserve FAIL=%s trans_alloc NULL=%s\n' "$(dmesg | grep -ac 'tre_reserve FAIL')" "$(dmesg | grep -ac 'trans_alloc NULL')"
	printf 'xmit IN=%s xmit pm_get=%s xmit skb_tx=%s\n' "$(dmesg | grep -ac 'xmit IN')" "$(dmesg | grep -ac 'xmit pm_get')" "$(dmesg | grep -ac 'xmit skb_tx')"
	printf 'fatal error=%s\n' "$(crashed)"
	echo "--- xmit IN 头 8 条（看队列 stop 标志）---"; dmesg | grep -a "xmit IN" | head -8
	echo "--- stats ---"; ip -s link show rmnet_ipa0 | tail -4; ip -s link show rmnet0 | tail -4
	echo "--- IRQ ---"; grep -iE "ipa|gsi" /proc/interrupts
else
	echo "跳过 [7][8]：网卡没起来 或 没拿到 IP"
fi

echo "============ END $(date +%F' '%T) ============"
say "I5 END"
echo "!! 收工：不要 down / 不要 rmmod；要换模块请断电重启 !!"
