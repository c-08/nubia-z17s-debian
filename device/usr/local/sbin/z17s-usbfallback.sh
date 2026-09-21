#!/bin/sh
# 确保串口控制台(/dev/ttyGS0)存在;若内核未自动绑定 gadget 则逐级兜底。
# 逐级: 1) 等 ttyGS0  2) modprobe g_serial  3) configfs 复合 gadget(gser+rndis)
G=/sys/kernel/config/usb_gadget/z17sfb
UDC=a800000.usb

for i in $(seq 1 15); do [ -e /dev/ttyGS0 ] && break; sleep 1; done

if [ ! -e /dev/ttyGS0 ]; then
	modprobe g_serial 2>/dev/null
	sleep 2
fi

if [ ! -e /dev/ttyGS0 ]; then
	mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
	mkdir -p "$G" 2>/dev/null
	if [ -d "$G" ]; then
		cd "$G" || exit 0
		echo 0x1d6b > idVendor 2>/dev/null
		echo 0x0104 > idProduct 2>/dev/null
		mkdir -p strings/0x409 2>/dev/null
		echo Z17SFB > strings/0x409/serialnumber 2>/dev/null
		echo Nubia > strings/0x409/manufacturer 2>/dev/null
		echo "Z17S Debian13" > strings/0x409/product 2>/dev/null
		mkdir -p configs/c.1/strings/0x409 2>/dev/null
		echo "usbnet-fallback" > configs/c.1/strings/0x409/configuration 2>/dev/null
		mkdir -p functions/gser.usb0 2>/dev/null
		mkdir -p functions/rndis.usb0 2>/dev/null
		ln -sf functions/gser.usb0 configs/c.1/ 2>/dev/null
		ln -sf functions/rndis.usb0 configs/c.1/ 2>/dev/null
		if [ ! -e /sys/class/udc/$UDC/../$UDC ]; then :; fi
		cat "$G/UDC" >/dev/null 2>&1
		printf '%s\n' "$UDC" > "$G/UDC" 2>/dev/null
	fi
fi

systemctl restart serial-getty@ttyGS0 2>/dev/null

# 网络接口(若存在)配置静态地址,便于 PC 直连
for i in $(seq 1 10); do [ -e /sys/class/net/usb0 ] && break; sleep 1; done
if [ -e /sys/class/net/usb0 ]; then
	ip link set usb0 up 2>/dev/null
	ip addr add 192.168.42.2/24 dev usb0 2>/dev/null
	logger -t z17s-usbfallback "usb0 up: $(ip -br addr show usb0 2>/dev/null | tr -s ' ')"
fi
logger -t z17s-usbfallback "done ttyGS0=$([ -e /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -e /sys/class/net/usb0 ] && echo yes || echo no)"
exit 0
