#!/bin/sh
# ============================================================================
# z17s G3 data-plane test  --  ONE variable at a time, every step fsync'd
#   precondition: /root/qmi_up.py is running with a long HOLD (call is up)
#   evidence: /root/g3-linkup.log  (+ z17s-logwatch kmsg at 0.25s)
# ============================================================================
LOG=/root/g3-linkup.log
exec >"$LOG" 2>&1

say() { echo "### $(date '+%F %T')  $*"; sync; }
k()   { echo "z17s-g3: $*" >/dev/kmsg 2>/dev/null; }

say "START  boot_id=$(cat /proc/sys/kernel/random/boot_id)"
k "START (linkup test)"
say "ipa loaded: $(lsmod | awk '/^ipa /{print $1" refcnt="$3}')"
say "link BEFORE: $(ip -o link show rmnet_ipa0 2>&1 | head -1)"
P=/sys/class/net/rmnet_ipa0/device/power
say "pm BEFORE: status=$(cat $P/runtime_status 2>&1) usage=$(cat $P/runtime_usage 2>&1) control=$(cat $P/control 2>&1)"
say "qmi proc: $(ps -o pid=,args= 2>/dev/null | grep -c '[q]mi_up.py') running"
say "--- last lines of qmi log:"; tail -6 /root/g3-qmi.log 2>&1; sync

# ---------------------------------------------------------------- STEP 1
say "STEP1  ip link set rmnet_ipa0 up"
k "STEP1 ip link up  >>>"
ip link set rmnet_ipa0 up
echo "       rc=$?"; sync
k "STEP1 ip link up  <<< rc=$?"
sleep 3
say "after STEP1: $(ip -o link show rmnet_ipa0 2>&1 | head -1)"
say "pm after STEP1: status=$(cat $P/runtime_status 2>&1) usage=$(cat $P/runtime_usage 2>&1)"

# ---------------------------------------------------------------- STEP 2
say "STEP2  ip addr add 10.118.65.25/30 dev rmnet_ipa0"
k "STEP2 addr add  >>>"
ip addr add 10.118.65.25/30 dev rmnet_ipa0
echo "       rc=$?"; sync
sleep 2
ip -o -4 addr show rmnet_ipa0 2>&1; sync

# ---------------------------------------------------------------- STEP 3
say "STEP3  ping -c3 -W3 10.118.65.26  (gateway)"
k "STEP3 ping gw  >>>"
ping -c 3 -W 3 10.118.65.26; echo "       ping_rc=$?"; sync
k "STEP3 ping gw  <<<"

# ---------------------------------------------------------------- STEP 4
say "STEP4  ping -c3 -W3 120.80.80.80  (DNS, carrier)"
k "STEP4 ping dns >>>"
ping -c 3 -W 3 120.80.80.80; echo "       ping_rc=$?"; sync
k "STEP4 ping dns <<<"

# ---------------------------------------------------------------- STEP 5
say "STEP5  ping L2-broadcast / arp sanity"
k "STEP5 neigh/arp >>>"
ip neigh show dev rmnet_ipa0 2>&1
ping -c 2 -W 2 10.118.65.26; echo "       ping_rc=$?"; sync
k "STEP5 neigh/arp <<<"

say "stats: $(ip -s link show rmnet_ipa0 2>&1 | tr '\n' '|')"
k "DONE (linkup test finished)"
say "DONE rc-ok"
