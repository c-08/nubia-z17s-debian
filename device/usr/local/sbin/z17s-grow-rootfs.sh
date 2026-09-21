#!/bin/sh
exit 0
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

root_source="$(findmnt -n -o SOURCE /)"
case "$root_source" in
  /dev/*) ;;
  *)
    echo "z17s-grow-rootfs: skip unsupported root source: $root_source"
    exit 0
    ;;
esac

if [ ! -b "$root_source" ]; then
  echo "z17s-grow-rootfs: skip missing block device: $root_source"
  exit 0
fi

echo "z17s-grow-rootfs: resizing $root_source"
/usr/sbin/resize2fs "$root_source"
findmnt -n -o SOURCE,SIZE,AVAIL,USE% /
