#!/bin/sh
# z17s-usbnet-rollback.sh -- emergency undo: drop the configfs gadget and go back to the
# legacy g_serial console-only setup.
set -u
G=/sys/kernel/config/usb_gadget/z17snet
UDC=a800000.usb

systemctl stop z17s-usbnet.service 2>/dev/null
systemctl stop 'serial-getty@ttyGS0.service' 2>/dev/null
pkill -f 'agetty.*ttyGS0' 2>/dev/null
sleep 1

if [ -s "$G/UDC" ]; then echo "" > "$G/UDC"; sleep 2; fi
cd "$G" 2>/dev/null && {
    rm -f configs/c.1/rndis.usb0 configs/c.1/gser.usb0 configs/c.1/acm.usb0 os_desc/c.1 2>/dev/null
    rmdir functions/rndis.usb0 2>/dev/null
    rmdir functions/gser.usb0  2>/dev/null
    rmdir functions/acm.usb0   2>/dev/null
    rmdir configs/c.1/strings/0x409 configs/c.1 2>/dev/null
    rmdir strings/0x409 2>/dev/null
    cd /; rmdir "$G" 2>/dev/null
}

modprobe g_serial 2>/dev/null
sleep 2
systemctl start 'serial-getty@ttyGS0.service' 2>/dev/null
echo "rollback done: ttyGS0=$([ -e /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -e /sys/class/net/usb0 ] && echo yes || echo no)"
