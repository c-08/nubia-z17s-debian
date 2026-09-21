#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The initramfs devtmpfs appears before udev has normalized device modes.
# D-Bus drops privileges and otherwise loses its first boot transaction.
chmod 0666 /dev/null /dev/zero /dev/full /dev/random /dev/urandom /dev/tty
modprobe g_serial 2>/dev/null || true
mkdir -p /dev/disk/by-partlabel /var/lib/rmtfs /mnt/persist

for path in /sys/block/sd*/sd*/uevent; do
  [ -f "$path" ] || continue
  part="$(basename "$(dirname "$path")")"
  name="$(sed -n 's/^PARTNAME=//p' "$path")"
  case "$name" in
    modemst1|modemst2|fsg|fsc|persist|misc)
      ln -sfn "/dev/$part" "/dev/disk/by-partlabel/$name"
      ;;
  esac
done

echo "z17s-early: ttyGS0=$([ -c /dev/ttyGS0 ] && echo ready || echo missing)" \
  >/dev/kmsg
