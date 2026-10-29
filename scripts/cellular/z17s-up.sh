#!/bin/sh
# ==========================================================================
# z17s-up.sh v2 -- Z17S 蜂窝一键上线（重启后全自动）
#
# ======================= 为什么改成这个顺序（2026-10-28 晚）=======================
# 之前 v1 的 insmod 在 modem online 之前，结果是「假连接」：
#   WDS 返回 IP、rmnet0 有地址、ipa0 tx 计数增长，但 modem 侧 tx_pkts_ok 恒 0，
#   ping -I rmnet0 100% 丢包，DL ch8 的 ridx 一动不动。
#
# 重新核对 10-27 22:38 那次唯一成功（r147.log，20/20 ping 通）的真实时序：
#   22:38:08  up 7 min              <- AP 只跑了 7 分钟，不是「modem 跑熟 2 小时」
#   dmesg 443 s  insmod
#   dmesg 444 s  0x23 -> result=0，notif -> modem 0x24 pipe=5 status=0
#   dmesg 445 s  ep18 aggregation bypass
#   然后 ping 20/20 通
#   关键：那一刻 modem 已经 'online' 且 'registered'（脚本 [5] 只用了 3 s 确认），
#         也就是说 **insmod 发生在 modem 完成注册之后**。
#
# 而所有失败 boots 都是：insmod 在开机 ~40 s（online 之前）-> modem 在 181 s
# online -> 241 s ipa_setup 跑完 -> 244 s 建呼叫 -> 假连接。
#
# ⇒ 结论：AP 侧 IPA 必须「晚于 modem 的注册」才起来。晚起时 modem 已经把自己
#   的 IPA 客户端 / DS 全部初始化完毕，双方做一次干净的 late-bind；
#   早起时 modem 的 IPA 客户端是在 DS 还没就绪时初始化的，之后建出来的
#   embedded call 是空的（包能进 GSI，但 modem 的 ipa_ul 不认）。
#
# ======================= 顺序 =======================
#   1. 等 modem 的 IPA 服务（qrtr 49 1 2）出现
#   2. modem online（只在 shutting-down 时发）+ 等 'registered'   <-- 提到 insmod 之前
#   3. 再等 POSTREG 秒让 DS 落定
#   4. insmod IPA 驱动（notif=1 / fidx=1 / pipe=5，与成功那次一致）
#   5. 等 rmnet_ipa0（modem 的 UC 0x35 回来才 register_netdev）
#   6. 建 rmnet0 并 up（成功那次就是先 up 再建呼叫）
#   7. QMAP
#   8. 建数据呼叫
#   9. 默认路由 + 自检（AP 侧 + modem 侧双判据）
#
# 用法：sh /root/z17s-up.sh [apn]
# 环境变量：POSTREG（默认 30）  PREWAIT（默认 0）
# 严禁：ip link set rmnet_ipa0 down / 热卸载 ipa / stop·start modem / reboot
#       / 同一 mux 建第二条呼叫 / 运行期 GSI·TABLE_INIT / z17s_gsi_ee* /
#         z17s_ep_cycle / z17s_patch_dst_ep / z17s_ready_go / z17s_uc_force
# ==========================================================================

# ★ ko 选择（2026-10-28 晚）：默认用 ipa-new-148.ko
#   ipa-new-147.ko     md5 9acc6dc6… = r147.log 记录的「唯一成功」那个二进制
#   ipa-new-148.ko     md5 7a6a94ec… = 147 + ep16 聚合关闭 + TX 唤醒修复，10-27 23:xx 验证过能上网
#   ipa-z17s-148.ko    md5 73bae150… = 另一次构建（差 37311 字节），10-28 全部失败用的就是它
# 可用 KO=/root/ipa-new-147.ko sh /root/z17s-up.sh 覆盖
KO=${KO:-/root/ipa-new-148.ko}
# APN：命令行 $1 优先；否则按注册到的 PLMN 自动选（换卡后不用改脚本）
APN=${1:-}
POSTREG=${POSTREG:-30}		# 注册完成 -> 再等这么久
PREWAIT=${PREWAIT:-0}		# 注册后到 insmod 的额外等待（360 已实测无效，回到 0 加快迭代）
# ★ PREWAIT=360 的依据：10-27 22:38 唯一成功那次（r147.log）
#   `22:38:08 up 7 min` + `dmesg 443 s insmod` ⇒ 开机到 insmod 整整 7 分钟，
#   而且是在 modem 已 online+registered 之后。10-28 所有失败都是 40~90 s 就 insmod。
#   要恢复「快」的话：PREWAIT=0 POSTREG=30 sh /root/z17s-up.sh
P=/sys/module/ipa/parameters
LOG=/root/z17s-up.log
CF=/root/z17s-call.log

say() { echo "[$(date +%H:%M:%S) up$(cut -d. -f1 /proc/uptime)s] $*" | tee -a "$LOG" >&2; }
die() { say "FATAL: $*"; exit 1; }

# 按注册到的 PLMN 选 APN（换 SIM 卡后自动适配）
#   460-00/02/04/07/08 中国移动 -> cmnet
#   460-01/06/09       中国联通 -> 3gnet
#   460-03/05/11       中国电信 -> ctnet
plmn_apn() {
	cur=$(timeout 20 qmicli -d qrtr://0 -p --nas-get-serving-system 2>/dev/null |
	      sed -n '/Current PLMN:/,/Description:/p')
	mcc=$(echo "$cur" | sed -n "s/.*MCC: '\([0-9]*\)'.*/\1/p" | head -1)
	mnc=$(echo "$cur" | sed -n "s/.*MNC: '\([0-9]*\)'.*/\1/p" | head -1)
	[ -n "$mcc" ] && say "  PLMN: ${mcc}-${mnc:-?}"
	case "$mcc" in
	460)
		case "$mnc" in
		0|2|4|7|8) echo cmnet ;;
		3|5|11)    echo ctnet ;;
		*)         echo 3gnet ;;
		esac ;;
	*) echo 3gnet ;;
	esac
}

: > "$LOG"
say "=== z17s-up v2 $(date) ==="
say "  POSTREG=${POSTREG}s APN=${APN:-<auto-by-PLMN>}"

# --------------------------------------------------- 1. 等 modem 的 IPA 服务
say "== [1] 等 modem IPA 服务 =="
i=0
while [ $i -lt 90 ]; do
	qrtr-lookup 2>/dev/null | grep -qE '^ *49 +1 +2 ' && break
	i=$((i + 1)); sleep 2
done
if [ $i -ge 90 ]; then
	say "  WARN: 180s 内没看到 IPA 服务（检查 rmtfs / z17s-oemfsg / oem 分区）"
else
	say "  IPA 服务在线（${i}0s 内）"
fi

# ------------------------- 2. 先把 modem 弄到 online + registered（早于 insmod）
say "== [2] modem online + 等注册（必须在 insmod 之前）=="
i=0; m=""
while [ $i -lt 60 ]; do
	m=$(timeout 20 qmicli -d qrtr://0 -p --dms-get-operating-mode 2>/dev/null |
	    sed -n "s/.*Mode: '\([a-z-]*\)'.*/\1/p")
	case "$m" in
	online)  say "  mode=online"; break ;;
	shutting-down)
		say "  mode=shutting-down -> 发 online"
		timeout 25 qmicli -d qrtr://0 -p --dms-set-operating-mode=online >/dev/null 2>&1
		;;
	'')  ;;
	*)   say "  mode=$m" ;;
	esac
	i=$((i + 1)); sleep 4
done
[ "$m" = online ] || die "modem 未能进入 online（uptime $(cut -d. -f1 /proc/uptime)s）"

i=0; reg=0
while [ $i -lt 75 ]; do
	# 只在 online 之后查 NAS；shutting-down 时发 NAS 会挂内核
	if timeout 20 qmicli -d qrtr://0 -p --nas-get-serving-system 2>/dev/null |
	   grep -q "Registration state: 'registered'"; then
		reg=1; break
	fi
	i=$((i + 1)); sleep 4
done
if [ "$reg" != 1 ]; then
	# 未注册时先把「是卡的问题还是网络的问题」分清，别浪费时间调 IPA
	say "  !! 未注册。诊断："
	say "     serving: $(timeout 20 qmicli -d qrtr://0 -p --nas-get-serving-system 2>/dev/null |
		grep -E "Registration state|PS:|Status:|Description" | tr -s ' \t' ' ' | tr '\n' '|')"
	say "     UIM: $(timeout 20 qmicli -d qrtr://0 -p --uim-get-card-status 2>/dev/null |
		grep -E "Slot \[|Card state|Application state|PIN1 state" | tr -s ' \t' ' ' | tr '\n' '|')"
	die "modem 未注册（卡/信号/APN？）"
fi
say "  registered（uptime $(cut -d. -f1 /proc/uptime)s）"

if [ -z "$APN" ]; then
	APN=$(plmn_apn | tail -1)
	say "  自动选 APN=$APN"
fi
# 防御：APN 只允许这几个已知值，避免命令替换被杂散输出污染（2026-10-28 踩过）
case "$APN" in
	cmnet|3gnet|ctnet|cmwap|3gwap|ctwap) ;;
	*) say "  WARN: APN 异常(\"$APN\")，回退 3gnet"; APN=3gnet ;;
esac

say "== [3] 再等 ${POSTREG}s 让 DS 落定 =="
[ "$PREWAIT" -gt 0 ] && sleep "$PREWAIT"
sleep "$POSTREG"

# --------------------------------- 4. insmod（此刻 modem 已 online + registered）
say "== [4] insmod =="
if lsmod | grep -q '^ipa '; then
	say "  ipa 已加载，跳过（注意：如果是早加载的，本次开机大概率仍是假连接）"
else
	[ -f "$KO" ] || die "缺少 $KO"
	SETUP0=$(dmesg | grep -c 'Z17STBL filter_count=')
	say "  ko: $KO  md5 $(md5sum "$KO" | cut -d' ' -f1)"
	P_FULL="z17s_rules=1 z17s_flt_ep=3 z17s_dst_ep=18 z17s_rt_slot=8 z17s_rt_tbl_idx=8
		z17s_flt_action=0 z17s_hdr_len=4 z17s_nocsum=1
		z17s_status_ep=-1 z17s_prog_status_ep=-1
		z17s_defroute=15 z17s_en_rule=0x20
		z17s_qwatch=1 z17s_kick=1 z17s_uc_dump=1 z17s_fc=0
		z17s_ic_delay=1500 z17s_ic_repeat=3 z17s_ic_gap=400
		z17s_qmi_flt=1 z17s_qmi_rt_tbl=8 z17s_qmi_src_pipe=-2 z17s_smp2p_rearm=1
		z17s_rx_zero=64 z17s_dl_rule=1 z17s_dl_flt_ep=5 z17s_dl_dst_ep=16 z17s_dl_rt_slot=9
		z17s_dump_setup=1 z17s_srv_rcv_sz=34021 z17s_tbl_every=0 z17s_lcl_every=0
		z17s_notif=1 z17s_notif_fidx=1 z17s_notif_pipe=5 z17s_qmi_ex=1
		z17s_rx_dump=0 z17s_noqstop=1 z17s_nobql=1"
	# 老 ko（147）没有 z17s_kick / z17s_nobql / z17s_rx_dump，被拒就降级重试
	P_MIN="z17s_rules=1 z17s_flt_ep=3 z17s_dst_ep=18 z17s_rt_slot=8 z17s_rt_tbl_idx=8
		z17s_flt_action=0 z17s_hdr_len=4 z17s_nocsum=1
		z17s_status_ep=-1 z17s_prog_status_ep=-1
		z17s_defroute=15 z17s_en_rule=0x20
		z17s_qwatch=1 z17s_uc_dump=1 z17s_fc=0
		z17s_ic_delay=1500 z17s_ic_repeat=3 z17s_ic_gap=400
		z17s_qmi_flt=1 z17s_qmi_rt_tbl=8 z17s_qmi_src_pipe=-2 z17s_smp2p_rearm=1
		z17s_rx_zero=64 z17s_dl_rule=1 z17s_dl_flt_ep=5 z17s_dl_dst_ep=16 z17s_dl_rt_slot=9
		z17s_dump_setup=1 z17s_srv_rcv_sz=34021 z17s_tbl_every=0 z17s_lcl_every=0
		z17s_notif=1 z17s_notif_fidx=1 z17s_notif_pipe=5 z17s_qmi_ex=1
		z17s_noqstop=1"
	# PONLY=min 时直接用 r147.sh 原版参数集（复现 10-27 22:38 成功那次）
	case "${PONLY:-}" in min) P_FULL="$P_MIN" ;; esac
	insmod "$KO" $P_FULL
	if [ $? -ne 0 ]; then
		say "  完整参数集被拒 -> 用精简参数集（r147.sh 原版）重试"
		insmod "$KO" $P_MIN || die "insmod 失败（两种参数集都不被接受）"
	fi
	say "  insmod OK  noqstop=$(cat $P/z17s_noqstop 2>/dev/null) nobql=$(cat $P/z17s_nobql 2>/dev/null) notif=$(cat $P/z17s_notif 2>/dev/null) fidx=$(cat $P/z17s_notif_fidx 2>/dev/null) pipe=$(cat $P/z17s_notif_pipe 2>/dev/null)"
	sleep 4
	SETUP1=$(dmesg | grep -c 'Z17STBL filter_count=')
	if [ "$SETUP1" != "$SETUP0" ]; then
		say "  ipa_setup 跑了：$(dmesg | grep -m1 'Z17STBL filter_count=' | sed 's/.*Z17STBL //')"
	else
		say "  ipa_setup 未触发（与 22:38 成功那次一致，正常）"
	fi
fi

# --------------------------------------------------------- 5. 等 rmnet_ipa0
say "== [5] 等 rmnet_ipa0 =="
i=0
while [ $i -lt 60 ]; do
	[ -d /sys/class/net/rmnet_ipa0 ] && break
	i=$((i + 1)); sleep 2
done
[ -d /sys/class/net/rmnet_ipa0 ] || die "rmnet_ipa0 未创建（modem 的 UC 0x35 没来）"
say "  OK"

# ------------------------------------------- 5b. ep18 聚合旁路（成功那次做过）
say "== [5b] ep18 聚合旁路 =="
if echo "18 0" > "$P/z17s_aggr_reg" 2>/dev/null; then
	say "  $(dmesg | grep -a 'Z17SAGGRREG' | tail -2 | sed 's/.*Z17SAGGRREG //' | tr '\n' ' ')"
else
	say "  WARN: 本 ko 不支持写 z17s_aggr_reg（EINVAL），跳过"
fi

# ------------------------------------------- 5c. ep16 聚合旁路（下行必须，2026-10-29）
# IPA 硬件把 DL 的多个 IP 包聚合成一个 GSI 帧，但 QMAP 头的 pkt_len 只写第一个
# 包的长度（实测 GSI len=4236 而 QMAP pkt_len=1400）。本驱动在
# ipa_endpoint_skb_build() 里把整帧直接交给协议栈，rmnet_map_ingress_handler()
# 只 trim 到 pkt_len 就上送，剩下的整段丢弃 => 下行只上送约 38%。
#
# 实测（同一 boot、同一呼叫，仅改这一处）：
#   关之前 2.3 KB/s，包长 4236/2824/5648/7060
#   关之后 324 KB/s，包长全是 1412，ipa_rx 与 rmnet0_rx 1:1 零丢失
say "== [5c] ep16 聚合旁路（下行）=="
if echo "16 0" > "$P/z17s_aggr_reg" 2>/dev/null; then
	dmesg | grep -a Z17SAGGRREG | tail -2 | sed "s/.*Z17SAGGRREG /  /" | tee -a "$LOG" >&2
else
	say "  WARN: 本 ko 不支持写 z17s_aggr_reg（EINVAL），下行会丢约 60%"
fi

# rx_dump 每收一个包打 4 行 dmesg，满速时每秒数百行，纯属噪声
echo N > "$P/z17s_rx_dump" 2>/dev/null

# --------------------------------------------- 6. rmnet0（建好就 up，照抄成功那次）
say "== [6] rmnet0 =="
if [ -e /sys/class/net/rmnet0 ]; then
	say "  rmnet0 已存在"
else
	ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 || die "建 rmnet0 失败"
	say "  created"
fi
ip link set rmnet_ipa0 up
ip link set rmnet0 up
sysctl -qw net.ipv6.conf.rmnet0.disable_ipv6=1 2>/dev/null && say "  rmnet0 IPv6 已关（WDS 只要 IPV4，无损失）"
say "  $(ip link show rmnet0 2>/dev/null | head -1 | sed 's/^[0-9]*: *//')"

# --------------------------------------------------------------------- 7. QMAP
say "== [7] QMAP =="
qmicli -d qrtr://0 -p --wda-set-data-format="link-layer-protocol=raw-ip,ul-protocol=qmap,dl-protocol=qmap,ep-type=embedded,ep-iface-number=1" >/dev/null 2>&1 \
	&& say "  data format set" || say "  WARN: data format 设置失败"

# --------------------------------------------------------------- 8. 数据呼叫
say "== [8] 数据呼叫 =="
if ps -ef | grep -q '[q]mi87.py'; then
	say "  已有呼叫进程 -> 绝不新建（重复 start_network 会让 modem 断言崩溃）"
elif ip -4 addr show rmnet0 2>/dev/null | grep -q 'inet '; then
	say "  rmnet0 已有 IP -> 绝不新建（可能是上一条呼叫的残留）"
else
	cd /root || exit 1
	setsid sh -c "BIND_MODE=before exec python3 /root/qmi87.py $APN 3 16 1 0 14400" \
		> "$CF" 2>&1 < /dev/null &
	say "  已启动，等待 IP..."
	i=0
	while [ $i -lt 40 ]; do
		ip -4 addr show rmnet0 2>/dev/null | grep -q 'inet ' && break
		i=$((i + 1)); sleep 1
	done
fi
ip -4 addr show rmnet0 2>/dev/null | grep -q 'inet ' || die "rmnet0 未拿到 IP"
ip link set rmnet0 up 2>/dev/null
say "  $(ip -4 addr show rmnet0 | grep 'inet ' | sed 's/^ *//')"

# --------------------------------------------------------------------- 9. 路由
say "== [9] 默认路由 =="
ip route replace default dev rmnet0 metric 50 || die "加默认路由失败"
say "  $(ip route get 223.5.5.5 | head -1)"

# -------------------------------------------------------------------- 10. 自检
say "== [10] 自检 =="
# ep16 聚合二次确认：开机时 [5c] 写在呼叫建立之前，IPA 后续初始化可能覆盖它。
# 这里在呼叫已经活着的时候再压一次，并直接读回寄存器确认。
dmesg -c >/dev/null 2>&1
echo "16 0" > "$P/z17s_aggr_reg" 2>/dev/null
# tail -2 的两行是 before / wrote 两条，取 head -1 拿 before 那条（带 en=）
AG=$(dmesg | grep -a Z17SAGGRREG | tail -2 | head -1 | sed "s/.*Z17SAGGRREG //")
case "$AG" in
*"en=0"*) say "  ep16 聚合已确认关闭：$AG" ;;
*)        say "  !! ep16 聚合未关（$AG）—— 下行会丢约 60%，检查 z17s_aggr_reg 是否可写" ;;
esac
ping -I rmnet0 -c 5 -W 2 -q 223.5.5.5 2>&1 | tail -2 | tee -a "$LOG"

# modem 侧才是真指标：AP 的 ch5 TX 完成事件即使 modem 没建呼叫也会正常回环
say "  等 16s 取 modem 侧计数..."
sleep 16
M=$(grep -a -o 'tx_pkts_ok=[0-9]* rx_pkts_ok=[0-9]*' "$CF" 2>/dev/null | tail -1)
say "  modem: ${M:-<无统计>}"
case "$M" in
*tx_pkts_ok=0*) say "  !! modem 没收到任何 UL 包 -> 这条呼叫是假的，不要用" ;;
*tx_pkts_ok=*)  say "  ★ modem 侧上行已计数 -> 数据通路打通" ;;
esac

say ""
say "完成。"
say "  若自检丢包，route-keeper 会在 10s 内撤掉默认路由，SSH 不受影响。"
say "  回退：ip route del default dev rmnet0 metric 50"
