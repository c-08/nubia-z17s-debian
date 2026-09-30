#!/bin/sh
# ---------------------------------------------------------------------------
# Z17S  G4 / pass-3 —— 序列器(sequencer)配置扫描
#
# pass-2 已确证：tre_reserve/skb_tx 都没失败（xmit skb_tx=0 / skb_tx trans=NULL=0），
# rmnet_ipa0 TX 出去 2 包，而 ping 期间 isr_ieob 一条不增
#   => TRE 提交进去了，IPA 从不完成它们。
#
# 怀疑点：AP_MODEM_TX 的 ENDP_INIT_SEQ
#   SEQ_TYPE     = 0x04  (IPA_SEQ_2_PASS_SKIP_LAST_UC)   ← 现表值
#   SEQ_REP_TYPE = 0x00  (空)                             ← sdm845 是 0x08 REP_DMA_PARSER
# 原始 msm8998 补丁的 seq_type 是另一个值（IPA_SEQ_2ND_PKT_PROCESS_PASS_NO_DEC_UCP）。
#
# 本脚本在一个 boot 内扫多组配置 —— 靠 pass-3 的两个东西：
#   * module_param z17s_seq / z17s_rep（按包重写 ENDP_INIT_SEQ，运行中可换）
#   * gsi_channel_trans_quiesce() 加了 3s 超时 ⇒ rmmod 不再锁机
#
# 安全：绝不 `ip link set rmnet_ipa0 down`；换配置只做 rmmod+insmod。
# ---------------------------------------------------------------------------
LOG=/root/ipa_g4_i4.log
K=/dev/kmsg
QMI=/root/g3-qmi-i3.log
say() { printf '<3>Z17SI4[%s] %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" > $K 2>/dev/null; }
cnt() { dmesg | grep -ac "$1"; }
ieob() { cnt 'isr_ieob'; }
int2ip() { echo "$1" | awk '{printf "%d.%d.%d.%d\n", int($1/16777216)%256, int($1/65536)%256, int($1/256)%256, $1%256}'; }
pfxlen()  { echo "$1" | awk '{n=$1;c=0;ok=1;for(i=31;i>=0;i--){b=int(n/(2^i))%2;if(b==1&&ok)c++;else ok=0}print c}'; }

exec >>"$LOG" 2>&1
echo "============ Z17S G4 / PASS3 sequencer sweep  $(date +%F' '%T) ============"
echo "boot_id = $(cat /proc/sys/kernel/random/boot_id)  uptime=$(cut -d' ' -f1 /proc/uptime)s"
say "I4 begin"

# ---------------------------------------------------------------- 一次性前置
echo
echo "--- [0] modem online + QMI PDP（只做一次） ---"
qmicli -d qrtr://0 --dms-set-operating-mode=online 2>&1 | head -1
sleep 8
qmicli -d qrtr://0 --nas-get-serving-system 2>&1 | grep -iE "registration state|description" | head -3

if ! pgrep -f '[q]mi_up2.py' >/dev/null 2>&1; then
	rm -f "$QMI"
	setsid python3 /root/qmi_up2.py 3gnet 3 16 1 0 3600 > "$QMI" 2>&1 &
	sleep 18
fi
grep -a "CARRIER" "$QMI" | tail -2
A_INT=$(grep -a "ipv4_address" "$QMI" | head -1 | grep -o '[0-9]*$')
G_INT=$(grep -a "ipv4_gateway_address" "$QMI" | head -1 | grep -o '[0-9]*$')
M_INT=$(grep -a "ipv4_gateway_subnet_mask" "$QMI" | head -1 | grep -o '[0-9]*$')
A=$(int2ip "$A_INT"); G=$(int2ip "$G_INT"); PFX=$(pfxlen "$M_INT")
[ -n "$PFX" ] && [ "$PFX" != "0" ] || PFX=30
echo ">>> A=$A/$PFX  GW=$G"
say "I4 carrier A=$A/$PFX GW=$G"

HIT=""

# ---------------------------------------------------------------- 单组配置
# $1=名称 $2=z17s_seq $3=z17s_rep
try() {
	NAME=$1; SEQ=$2; REP=$3
	echo
	echo "################ CONFIG $NAME  seq=$SEQ rep=$REP ################"
	say "I4 CFG $NAME seq=$SEQ rep=$REP"

	# --- 清场（不 down 网卡！）
	ip link del rmnet0 2>/dev/null
	if lsmod | grep -q '^ipa '; then
		BEFORE_Q=$(tc -s qdisc show dev rmnet_ipa0 2>/dev/null | grep backlog)
		echo "  pre-rmmod qdisc: $BEFORE_Q"
		rmmod ipa 2>&1; echo "  ### rmmod rc=$?"
		say "I4 rmmod rc=$?"
	fi
	if lsmod | grep -q '^ipa '; then
		echo "  !!! ipa 仍在内核，跳过本组"
		say "I4 rmmod FAILED - skip"
		return
	fi

	# --- 载入并写死 autosuspend
	if [ "$SEQ" = "-1" ] && [ "$REP" = "-1" ]; then
		insmod /root/ipa-instr3.ko 2>&1
	else
		insmod /root/ipa-instr3.ko z17s_seq=$SEQ z17s_rep=$REP 2>&1
	fi
	echo "  ### insmod rc=$?"
	say "I4 insmod rc=$?"
	echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms 2>/dev/null
	echo "  pm: control=$(cat /sys/bus/platform/devices/1e40000.ipa/power/control) delay=$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms) status=$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)"

	E0=$(ieob)
	# --- 起链路 + rmnet0 + L3
	ip link set rmnet_ipa0 up 2>&1; echo "  ### linkup rc=$?"
	say "I4 linkup rc=$?"
	modprobe rmnet 2>/dev/null
	ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 2>&1; echo "  ### link-add rc=$?"
	ip link set rmnet0 up 2>&1
	ip addr add "$A/$PFX" dev rmnet0 2>&1
	ip route add "$G"/32 dev rmnet0 2>&1

	# --- ping（txqueuelen 调小，别让 qdisc 积一堆）
	ip link set rmnet0 txqueuelen 16 2>/dev/null
	ip link set rmnet_ipa0 txqueuelen 16 2>/dev/null
	P0=$(cat /sys/class/net/rmnet_ipa0/statistics/tx_packets 2>/dev/null)
	echo "  --- ping -c 4 ---"
	ping -c 4 -W 2 -I rmnet0 "$G" 2>&1 | tail -3
	PRC=$?
	sleep 2
	P1=$(cat /sys/class/net/rmnet_ipa0/statistics/tx_packets 2>/dev/null)
	R1=$(cat /sys/class/net/rmnet0/statistics/rx_packets 2>/dev/null)
	E1=$(ieob)
	printf '  >>> rmnet_ipa0 tx_packets %s -> %s | rmnet0 rx_packets=%s | isr_ieob %s -> %s | ping rc=%s\n' \
		"$P0" "$P1" "$R1" "$E0" "$E1" "$PRC"
	echo "  --- Z17SIPA2 ---"; dmesg | grep -a Z17SIPA2 | tail -12
	echo "  --- stats ---"; ip -s link show rmnet_ipa0 | tail -4
	say "I4 CFG $NAME done ping_rc=$PRC tx=$P1 rx=$R1 ieob=$E1"

	if [ "$PRC" = "0" ]; then
		HIT="$NAME seq=$SEQ rep=$REP"
		echo
		echo "  ************** 成功！CONFIG $NAME 通了 **************"
		say "I4 !!! HIT $NAME seq=$SEQ rep=$REP"
		return 1
	fi
	return 0
}

for CFG in "orig12_0:12:0" "sdm845_4_8:4:8" "orig12_8:12:8" "onepass2_8:2:8" "base4_0:4:0"; do
	N=${CFG%%:*}; R=${CFG#*:}; S=${R%%:*}; RP=${R#*:}
	try "$N" "$S" "$RP" || break
done

echo
echo "=========== 汇总 ==========="
if [ -n "$HIT" ]; then echo "命中：$HIT"; else echo "全部配置都没通（未命中）"; fi
echo "isr_ieob 总数 = $(ieob)   trans_COMPLETE = $(cnt 'trans_COMPLETE')"
echo "tre_reserve FAIL = $(cnt 'tre_reserve FAIL')  trans_alloc NULL = $(cnt 'trans_alloc NULL')"
echo "xmit pm_get = $(cnt 'xmit pm_get')  xmit skb_tx = $(cnt 'xmit skb_tx')  quiesce TIMEOUT = $(cnt 'quiesce TIMEOUT')"
echo "--- xmit IN 头 12 条（看队列是否被停） ---"; dmesg | grep -a "xmit IN" | head -12
echo "--- IRQ ---"; grep -iE "ipa|gsi" /proc/interrupts
echo "============ END $(date +%F' '%T) ============"
say "I4 END hit=[$HIT]"
echo "!! 收工：不要 down；要换模块请断电重启 !!"
