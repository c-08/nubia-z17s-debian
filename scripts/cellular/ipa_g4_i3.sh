#!/bin/sh
# ---------------------------------------------------------------------------
# Z17S  G4 / instrumentation pass-2, CLEAN-BOOT run
#
# 与上一版的区别（上一版把机器锁死了）：
#   * 干净开机后 ipa 本来就没加载 ⇒ 直接 insmod，**不 rmmod**
#   * **全程不执行 `ip link set rmnet_ipa0 down`**（__gsi_channel_stop 会无超时等事务）
#   * autosuspend=-1 在任何 link up 之前写死
#   * **先把 modem 拉 online 再 insmod**（让 modem 侧 IPA service 先存在）
#
# 读数（tag Z17SIPA2）：isr_ieob / tre_reserve FAIL / trans_alloc NULL /
#                        skb_tx trans=NULL / xmit pm_get / xmit skb_tx / wake_queue_work
# ---------------------------------------------------------------------------
LOG=/root/ipa_g4_i3.log
K=/dev/kmsg
QMI=/root/g3-qmi-i3.log
say() { printf '<3>Z17SI3[%s] %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" > $K 2>/dev/null; }
ieob() { dmesg | grep -ac 'isr_ieob'; }
int2ip() { echo "$1" | awk '{printf "%d.%d.%d.%d\n", int($1/16777216)%256, int($1/65536)%256, int($1/256)%256, $1%256}'; }
pfxlen()  { echo "$1" | awk '{n=$1;c=0;ok=1;for(i=31;i>=0;i--){b=int(n/(2^i))%2;if(b==1&&ok)c++;else ok=0}print c}'; }

exec >>"$LOG" 2>&1

echo "============ Z17S G4 / PASS2 clean-boot  $(date +%F' '%T) ============"
echo "boot_id = $(cat /proc/sys/kernel/random/boot_id)"
echo "uptime  = $(cut -d' ' -f1 /proc/uptime)s"
echo "ipa loaded at start? $(lsmod | grep -c '^ipa ')"
echo "PM before: control=$(cat /sys/bus/platform/devices/1e40000.ipa/power/control 2>/dev/null) delay=$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms 2>/dev/null)"
say "I3 begin"

# ---------------------------------------------------------------- [1] modem online FIRST
echo
echo "--- [1] modem online (重启后射频默认 shutting-down) ---"
qmicli -d qrtr://0 --dms-set-operating-mode=online 2>&1 | head -2
echo "### set-online rc=$?"
sleep 8
qmicli -d qrtr://0 --dms-get-operating-mode 2>&1 | head -3
qmicli -d qrtr://0 --nas-get-serving-system 2>&1 | grep -iE "registration state|mcc|mnc|description|roaming" | head -6
say "I3 modem-online done"

# ---------------------------------------------------------------- [2] insmod
echo
echo "--- [2] insmod /root/ipa-instr2.ko  (NO rmmod) ---"
insmod /root/ipa-instr2.ko 2>&1; echo "### rc=$?"
say "I3 insmod rc=$?"

# ---------------------------------------------------------------- [3] pin autosuspend
echo
echo "--- [3] pin autosuspend = -1 (在 link up 之前) ---"
echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms 2>&1; echo "### rc=$?"
printf 'control=%s delay=%s status=%s\n' \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/control)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)"
say "I3 pinned"

# ---------------------------------------------------------------- [4] probe readout
echo
echo "--- [4] probe 读数 ---"
dmesg | grep -aE "ipa 1e40000|Z17SIPA" | tail -45
echo "isr_ieob after setup  = $(ieob)"
say "I3 probe ok isr_ieob=$(ieob)"

# ---------------------------------------------------------------- [5] QMI PDP
echo
echo "--- [5] qmi_up2.py（DPM+WDS，hold 3600）---"
rm -f "$QMI"
setsid python3 /root/qmi_up2.py 3gnet 3 16 1 0 3600 > "$QMI" 2>&1 &
sleep 18
grep -aE "START_NETWORK|CARRIER|FAIL|rc=" "$QMI" | tail -12
echo "pid: $(pgrep -af '[q]mi_up2.py' | head -1)"
echo "isr_ieob after PDP   = $(ieob)"
say "I3 qmi done isr_ieob=$(ieob)"

# ---------------------------------------------------------------- [6] link up
echo
echo "--- [6] ip link set rmnet_ipa0 up ---"
ip link set rmnet_ipa0 up 2>&1; echo "### rc=$?"
say "I3 linkup rc=$?"
ip -br link show rmnet_ipa0
echo "isr_ieob after linkup = $(ieob)"

# ---------------------------------------------------------------- [7] rmnet0 + L3
A_INT=$(grep -a "ipv4_address" "$QMI" | head -1 | grep -o '[0-9]*$')
G_INT=$(grep -a "ipv4_gateway_address" "$QMI" | head -1 | grep -o '[0-9]*$')
M_INT=$(grep -a "ipv4_gateway_subnet_mask" "$QMI" | head -1 | grep -o '[0-9]*$')
A=$(int2ip "$A_INT"); G=$(int2ip "$G_INT"); PFX=$(pfxlen "$M_INT")
[ -n "$PFX" ] && [ "$PFX" != "0" ] || PFX=30
echo
echo "--- [7] 解析 -> A=$A/$PFX GW=$G ---"
modprobe rmnet 2>&1; echo "### modprobe rc=$?"
ip link del rmnet0 2>/dev/null
ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 2>&1; echo "### link-add rc=$?"
say "I3 rmnet0 add rc=$?"
ip link set rmnet0 up 2>&1; echo "### up rc=$?"
ip addr add "$A/$PFX" dev rmnet0 2>&1; echo "### addr rc=$?"
ip route add "$G"/32 dev rmnet0 2>&1; echo "### route rc=$?"
ip -o -4 addr show rmnet0; ip route show dev rmnet0
echo "default:"; ip -o route show default

# ---------------------------------------------------------------- [8] ping
echo
echo "=========== [8] ping -c 4 -W 2 via rmnet0 -> $G ==========="
say "I3 ping start isr_ieob=$(ieob)"
ping -c 4 -W 2 -I rmnet0 "$G"; echo "### ping rc=$?"
say "I3 ping done rc=$?"

# ---------------------------------------------------------------- [9] ★ 关键读数
echo
echo "=========== [9] ★ Z17SIPA2 读数 ==========="
echo "--- 前 15 条 ---"; dmesg | grep -a Z17SIPA2 | head -15
echo "--- 后 30 条 ---"; dmesg | grep -a Z17SIPA2 | tail -30
echo "--- 计数 ---"
printf 'isr_ieob        = %s\n' "$(ieob)"
printf 'tre_reserve FAIL= %s\n' "$(dmesg | grep -ac 'tre_reserve FAIL')"
printf 'trans_alloc NULL= %s\n' "$(dmesg | grep -ac 'trans_alloc NULL')"
printf 'skb_tx trans=NULL= %s\n' "$(dmesg | grep -ac 'skb_tx trans=NULL')"
printf 'xmit pm_get     = %s\n' "$(dmesg | grep -ac 'xmit pm_get')"
printf 'xmit skb_tx     = %s\n' "$(dmesg | grep -ac 'xmit skb_tx')"
printf 'wake_queue_work = %s\n' "$(dmesg | grep -ac 'wake_queue_work')"
echo "--- IRQ ---"; grep -iE "ipa|gsi" /proc/interrupts
echo "--- stats ---"; ip -s link show rmnet_ipa0; ip -s link show rmnet0
echo "--- qdisc ---"; tc -s qdisc show dev rmnet_ipa0
echo "--- ipa power ---"; printf 'status=%s usage=%s susp_ms=%s\n' \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_usage)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_suspended_time)"
echo "============ END  $(date +%F' '%T) ============"
say "I3 END"
echo "!! 收工：不要 down / 不要 rmmod；要换模块请直接断电重启 !!"
