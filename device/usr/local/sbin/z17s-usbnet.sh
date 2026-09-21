#!/bin/sh
# z17s-usbnet.sh -- bring up a configfs USB composite gadget on the Z17S:
#     rndis.usb0 -> usb0    network interface (Windows ICS shares the PC's internet to it)
#     acm.usb0   -> ttyGS0  kernel console + serial-getty (keeps the COM port alive)
#
# Why configfs and not the legacy drivers:
#   drivers/usb/gadget/legacy/multi.c:307 calls can_support_ecm() unconditionally and
#   returns -EINVAL when it fails.  can_support_ecm() (function/u_ether.h:296) first tests
#   gadget_is_altset_supported(), a flag no UDC in this tree ever sets -> g_multi can never
#   bind on dwc3 ("failed to start g_multi: -22").  f_rndis has no such requirement.
#
# Why "acm" and not "gser" for the serial port:
#   f_serial.c (gser) advertises USB_CLASS_VENDOR_SPEC -> Windows has no driver for it.
#   f_acm.c advertises USB_CLASS_COMM / CDC_SUBCLASS_ACM, which the Windows inbox driver
#   matches ("USB\Class_02&SubClass_02&Prot_01" in usbser.inf) -> shows up as a COM port.
#
# Why the OS descriptors matter:
#   Windows binds netrndis.inf only when the device exposes the Microsoft OS descriptor
#   with CompatibleID "RNDIS" (-> hardware id USB\MS_COMP_RNDIS).  Requires all four:
#     os_desc/b_vendor_code = 0xcd
#     os_desc/qw_sign       = MSFT100        <-- NOT "qwSignature"
#     functions/rndis.usb0/os_desc/interface.rndis/compatible_id     = RNDIS
#     functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id = 5162001
#
# ---------------------------------------------------------------------------------------
# v3 (2026-09-20) -- WHY THIS IS STARTED BY A TIMER AND NOT BY multi-user.target:
#   v2 was WantedBy=multi-user.target and hung the whole boot at "Starting
#   z17s-early.service" (the panel showed no probe, no network, no console).  Root cause is
#   the class of bug, not one line: a oneshot sitting in the boot critical path that (a)
#   calls systemctl on units that are ordered against it, (b) logs through /dev/log before
#   dbus/journald are fully live, and (c) tears down the very console the boot log is
#   going to.  Now z17s-usbnet.timer fires ~45 s AFTER boot, so nothing here can ever
#   block boot.  On top of that:
#     * log() no longer calls logger(1) -- plain append, no syslog dependency
#     * every step that can block in the kernel (modprobe -r, UDC release/bind) is wrapped
#       in `timeout`, so a stuck syscall can never wedge us forever
#     * any failure runs restore_gserial(), which puts the author's g_serial console back,
#       so we always keep a COM port as the escape hatch
# ---------------------------------------------------------------------------------------
set -u

G=/sys/kernel/config/usb_gadget/z17snet
UDC=a800000.usb
LOG=/var/log/z17s-usbnet.log
IP=192.168.137.2
GW=192.168.137.1
PREFIX=24

# hard cap on steps that touch the kernel
T_MODPROBE=25
T_UDC=20

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

teardown_gadget() {
    [ -e "$G/UDC" ] && printf '' > "$G/UDC" 2>/dev/null
    rm -f "$G/configs/c.1/rndis.usb0" 2>/dev/null
    rm -f "$G/configs/c.1/acm.usb0"   2>/dev/null
    rm -f "$G/configs/c.1/gser.usb0"  2>/dev/null
    rm -f "$G/os_desc/c.1"            2>/dev/null
    rmdir "$G/functions/rndis.usb0" 2>/dev/null
    rmdir "$G/functions/acm.usb0"   2>/dev/null
    rmdir "$G/functions/gser.usb0"  2>/dev/null
    rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null
    rmdir "$G/configs/c.1" 2>/dev/null
    rmdir "$G/strings/0x409" 2>/dev/null
    [ -d "$G" ] && { cd /; rmdir "$G" 2>/dev/null; }
}

# Put the legacy console-only gadget back so we never end up without a COM port.
restore_gserial() {
    log "ROLLBACK: tearing down configfs gadget and restoring g_serial console"
    teardown_gadget
    timeout "$T_MODPROBE" modprobe g_serial 2>/dev/null
    i=0
    while [ "$i" -lt 10 ]; do [ -e /dev/ttyGS0 ] && break; i=$((i + 1)); sleep 1; done
    timeout 25 systemctl restart 'serial-getty@ttyGS0.service' 2>/dev/null
    log "ROLLBACK done: ttyGS0=$([ -e /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -e /sys/class/net/usb0 ] && echo yes || echo no)"
}

trap 'log "ROLLBACK: script aborted (signal)"; restore_gserial; exit 1' INT TERM

log "=== start (udc=$UDC ip=$IP/$PREFIX gw=$GW) ==="

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
if [ ! -d /sys/kernel/config/usb_gadget ]; then
    log "FATAL no configfs usb_gadget"
    exit 1
fi

# ---------------------------------------------------------------- 1. free the UDC
# The legacy g_serial module holds the UDC and owns ttyGS0 line 0.  Release both before
# creating the configfs instances, otherwise ttyGS0 would move to ttyGS1.
# NOTE: stopping a getty on the serial console can block for the full 90s systemd
# TimeoutStopSec (gs_close waits on the port while the gadget is being torn down),
# so bound it with timeout(1) and fall back to killing it.
timeout 12 systemctl stop 'serial-getty@ttyGS0.service' 2>/dev/null
pkill -9 -f 'agetty.*ttyGS0' 2>/dev/null
sleep 2
if lsmod | grep -q '^g_serial'; then
    timeout "$T_MODPROBE" modprobe -r g_serial 2>/dev/null
    log "g_serial unloaded (still loaded: $(lsmod | grep -c '^g_serial'))"
fi

# unbind whatever a previous run left behind
if [ -s "$G/UDC" ]; then
    timeout "$T_UDC" sh -c "printf '' > $G/UDC" 2>/dev/null
    sleep 2
fi
i=0
while [ "$i" -lt 8 ]; do
    [ "$(cat /sys/class/udc/$UDC/state 2>/dev/null)" = "not attached" ] && break
    i=$((i + 1)); sleep 1
done
log "udc state after release: $(cat /sys/class/udc/$UDC/state 2>/dev/null)"

# drop functions from an earlier layout (gser was replaced by acm)
if [ -d "$G" ]; then
    rm -f "$G/configs/c.1/gser.usb0" 2>/dev/null
    rmdir "$G/functions/gser.usb0" 2>/dev/null
fi

# ------------------------------------------------------------- 2. build the gadget
mkdir -p "$G"
cd "$G" || { log "FATAL cd $G"; restore_gserial; exit 1; }

# os_desc attributes are write-once while bound; reset the flag first
[ -e os_desc/use ] && printf '0' > os_desc/use 2>/dev/null

printf '0x0525' > idVendor          # Linux-USB "RNDIS gadget" id, present in Windows INFs
printf '0xa4a2' > idProduct
printf '0x0100' > bcdDevice
printf '0x0200' > bcdUSB

# NOTE: the serial number is deliberately bumped whenever the descriptor layout changes.
# Windows caches "this device has no MS OS descriptors" per device instance, keyed by
# VID/PID/serial; changing the serial forces a full re-enumeration so RNDIS is re-matched.
SERIAL='Z17SNET0005'

mkdir -p strings/0x409
printf '%s' "$SERIAL"     > strings/0x409/serialnumber
printf '%s' 'Nubia'       > strings/0x409/manufacturer
printf '%s' 'Z17S Debian13 USB net' > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
printf '%s' 'rndis + serial' > configs/c.1/strings/0x409/configuration
printf '250' > configs/c.1/MaxPower

# --- rndis: Android-style interface class codes + MS OS compatible id --------
# Windows' inbox rndiscmp.inf matches two hardware ids:
#     USB\MS_COMP_RNDIS&MS_SUBCOMP_5162001      <- from the MS OS descriptors
#     USB\Class_EF&SubClass_04&Prot_01          <- from the IAD class codes
# Linux's f_rndis defaults the IAD to COMM/ETHERNET (02/06/00), which Windows
# reads as CDC-ECM and has no driver for.  f_rndis.c:31-33 copies these three
# configfs attributes into the IAD, so set them to the Android RNDIS triple.
# NOTE: these three take a 2-character HEX string (no 0x prefix) -- usb_ether_configfs.h
# builds them with kstrtou8(page, 16, ...) and reads back with %02x.  Writing "0xef"
# silently stores 0x00, which is what made the first attempt look like it did nothing.
mkdir -p functions/rndis.usb0
printf 'ef' > functions/rndis.usb0/class    2>/dev/null   # USB_CLASS_MISC
printf '04' > functions/rndis.usb0/subclass 2>/dev/null   # MISC_SUBCLASS_IAD
printf '01' > functions/rndis.usb0/protocol 2>/dev/null   # MISC_PROTOCOL_IAD
printf 'RNDIS'   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id     2>/dev/null
printf '5162001' > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id 2>/dev/null
log "rndis iad codes: class=$(cat functions/rndis.usb0/class) subclass=$(cat functions/rndis.usb0/subclass) protocol=$(cat functions/rndis.usb0/protocol)"

# --- serial (acm) -----------------------------------------------------------
HAS_ACM=0
if mkdir -p functions/acm.usb0 2>/dev/null; then HAS_ACM=1; fi
# declare this port as the kernel console (matches console=ttyGS0 on the cmdline)
[ -e functions/acm.usb0/console ] && printf '1' > functions/acm.usb0/console 2>/dev/null
log "acm instance: $HAS_ACM (ttyGS0: $([ -e /dev/ttyGS0 ] && echo yes || echo no))"

# --- gadget-level OS descriptor ---------------------------------------------
printf '0xcd'    > os_desc/b_vendor_code
printf 'MSFT100' > os_desc/qw_sign
printf '1'       > os_desc/use

ln -sf functions/rndis.usb0 configs/c.1/
[ "$HAS_ACM" = 1 ] && ln -sf functions/acm.usb0 configs/c.1/
ln -sf configs/c.1 os_desc/

# ---------------------------------------------------------------- 3. bind the UDC
timeout "$T_UDC" sh -c "printf '%s\n' '$UDC' > $G/UDC" 2>/dev/null
BIND_RC=$?
sleep 3
STATE="$(cat /sys/class/udc/$UDC/state 2>/dev/null)"
log "bind rc=$BIND_RC -> udc state: $STATE"
if [ "$BIND_RC" != 0 ] && [ "$STATE" != "configured" ] && [ "$STATE" != "not attached" ]; then
    log "bind failed, rolling back"
    restore_gserial
    exit 1
fi

# ------------------------------------------------------------- 4. configure usb0
i=0
while [ "$i" -lt 20 ]; do [ -e /sys/class/net/usb0 ] && break; i=$((i + 1)); sleep 1; done

if [ -e /sys/class/net/usb0 ]; then
    ip link set usb0 up
    ip addr replace "$IP/$PREFIX" dev usb0
    ip route replace default via "$GW" dev usb0 metric 1000 2>/dev/null
    log "usb0 UP: $(ip -br addr show usb0 | tr -s ' ')"
    log "default routes: $(ip route show default | tr '\n' '|')"
else
    log "WARN usb0 never appeared"
fi

# ------------------------------------------------------- 5. bring the getty back
i=0
while [ "$i" -lt 15 ]; do [ -e /dev/ttyGS0 ] && break; i=$((i + 1)); sleep 1; done
if [ -e /dev/ttyGS0 ]; then
    timeout 25 systemctl restart 'serial-getty@ttyGS0.service' 2>/dev/null
    log "ttyGS0 ok, serial-getty: $(systemctl is-active serial-getty@ttyGS0.service 2>/dev/null)"
else
    log "WARN ttyGS0 missing - serial console lost"
fi

log "=== done (usb0=$([ -e /sys/class/net/usb0 ] && echo up || echo down)) ==="
exit 0
