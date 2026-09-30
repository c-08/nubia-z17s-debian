#!/bin/sh
# ---------------------------------------------------------------------------
# Z17S  G4 instrumentation pass 2 run
#
# Goal: find out WHY rmnet_ipa0 TX stops after ~2 packets.
#   pass-2 traces (tag Z17SIPA2):
#     gsi_isr_ieob        - does ANY completion ever arrive?
#     tre_reserve FAIL    - is the TRE pool exhausted?
#     trans_alloc NULL    - which alloc failed
#     skb_tx trans=NULL   - endpoint level
#     xmit pm_get / skb_tx ret - ipa_start_xmit bail-outs
#
# Safety: serial logger is running (COM15, hb fresh).
#         rmnet_ipa0 is brought DOWN before rmmod, autosuspend is pinned to -1
#         immediately after insmod so ipa_power_disable() can never run.
# ---------------------------------------------------------------------------
LOG=/root/ipa_g4_i2.log
K=/dev/kmsg
say() { printf '<3>Z17SI2[%s] %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" > $K 2>/dev/null; }
int2ip() { echo "$1" | awk '{printf "%d.%d.%d.%d\n", int($1/16777216)%256, int($1/65536)%256, int($1/256)%256, $1%256}'; }
pfxlen()  { echo "$1" | awk '{n=$1;c=0;ok=1;for(i=31;i>=0;i--){b=int(n/(2^i))%2;if(b==1&&ok)c++;else ok=0}print c}'; }

exec >>"$LOG" 2>&1

A_INT=$(grep -a "wds.settings.ipv4_address" /root/g3-qmi-warm.log | head -1 | grep -o '[0-9]*$')
G_INT=$(grep -a "wds.settings.ipv4_gateway_address" /root/g3-qmi-warm.log | head -1 | grep -o '[0-9]*$')
M_INT=$(grep -a "wds.settings.ipv4_gateway_subnet_mask" /root/g3-qmi-warm.log | head -1 | grep -o '[0-9]*$')
A=$(int2ip "$A_INT"); G=$(int2ip "$G_INT"); PFX=$(pfxlen "$M_INT")
[ -n "$PFX" ] && [ "$PFX" != "0" ] || PFX=30

echo "============ Z17S G4 / INSTRUMENTATION PASS 2  $(date +%F' '%T) ============"
echo "boot_id  = $(cat /proc/sys/kernel/random/boot_id)"
echo "uptime   = $(cut -d' ' -f1 /proc/uptime)s"
echo "carrier  = A=$A/$PFX  GW=$G"
echo "qmi hold = $(pgrep -af '[q]mi_up.py' | head -1)"
say "I2 begin A=$A/$PFX GW=$G"

echo
echo "--- [0] pre-state ---"
lsmod | grep -E '^(ipa|rmnet) '
ip -br link show | grep -E 'rmnet|usb0'
echo "Z17SIPA2 count before = $(dmesg | grep -ac Z17SIPA2)"

echo
echo "--- [1] ip link del rmnet0 ---"; ip link del rmnet0 2>&1; echo "### rc=$?"
say "I2 del rmnet0 rc=$?"
echo "--- [2] ip link set rmnet_ipa0 down ---"; ip link set rmnet_ipa0 down 2>&1; echo "### rc=$?"
say "I2 link-down rc=$?"
echo "--- [3] rmmod ipa ---"; rmmod ipa 2>&1; echo "### rc=$?"
say "I2 rmmod rc=$?"
sleep 1
lsmod | grep -E '^(ipa|rmnet) ' || echo "(ipa gone)"

echo
echo "--- [4] insmod /root/ipa2.ko ---"; insmod /root/ipa2.ko 2>&1; echo "### rc=$?"
say "I2 insmod rc=$?"
sleep 3
lsmod | grep -E '^(ipa|rmnet) '

echo
echo "--- [5] pin autosuspend = -1 (MUST be before any link up) ---"
echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms 2>&1; echo "### rc=$?"
printf 'control=%s delay=%s status=%s\n' \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/control)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)"
say "I2 pinned"

echo
echo "--- probe dmesg (IPA/GSI + Z17SIPA2 from setup) ---"
dmesg | grep -aE "ipa 1e40000|Z17SIPA" | tail -30
echo "Z17SIPA2 count after probe = $(dmesg | grep -ac Z17SIPA2)"
echo "isr_ieob so far:"; dmesg | grep -a "isr_ieob" | tail -10

echo
echo "--- [6] ip link set rmnet_ipa0 up ---"; ip link set rmnet_ipa0 up 2>&1; echo "### rc=$?"
say "I2 link-up rc=$?"
ip -br link show rmnet_ipa0

echo
echo "--- [7] modprobe rmnet + add rmnet0 (QMAP) ---"
modprobe rmnet 2>&1; echo "### rc=$?"
ip link del rmnet0 2>/dev/null
ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0 2>&1; echo "### rc=$?"
say "I2 rmnet0 add rc=$?"
ip link set rmnet0 up 2>&1; echo "### rc=$?"
ip addr add "$A/$PFX" dev rmnet0 2>&1; echo "### rc=$?"
ip route add "$G"/32 dev rmnet0 2>&1; echo "### rc=$?"
[ -n "$GWOK" ] || true
ip -o -4 addr show rmnet0
ip route show dev rmnet0
echo "default:"; ip -o route show default

echo
echo "=========== PING x4 via rmnet0 -> GW $G ==========="
say "I2 ping start"
ping -c 4 -W 2 -I rmnet0 "$G"; echo "### ping rc=$?"
say "I2 ping done rc=$?"

echo
echo "--- Z17SIPA2 traces after ping ---"
dmesg | grep -a Z17SIPA2 | tail -40
echo "--- counts ---"
printf 'isr_ieob   = %s\n' "$(dmesg | grep -ac 'isr_ieob')"
printf 'tre_reserve= %s\n' "$(dmesg | grep -ac 'tre_reserve FAIL')"
printf 'trans_alloc= %s\n' "$(dmesg | grep -ac 'trans_alloc NULL')"
printf 'pm_get bail= %s\n' "$(dmesg | grep -ac 'xmit pm_get')"
printf 'skb_tx bail= %s\n' "$(dmesg | grep -ac 'xmit skb_tx')"
echo "--- IRQ ---"; grep -iE "ipa|gsi" /proc/interrupts
echo "--- stats ---"; ip -s link show rmnet_ipa0; ip -s link show rmnet0
echo "--- qdisc ---"; tc -s qdisc show dev rmnet_ipa0
echo "--- ipa power ---"; printf 'status=%s usage=%s susp_ms=%s\n' \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_status)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_usage)" \
  "$(cat /sys/bus/platform/devices/1e40000.ipa/power/runtime_suspended_time)"
echo "============ END $(date +%F' '%T) ============"
say "I2 END"
