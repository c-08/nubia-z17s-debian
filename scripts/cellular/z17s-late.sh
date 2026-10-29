#!/bin/sh
# z17s-late.sh -- 等到 uptime >= TARGET 再跑 z17s-up.sh
# 目的：复现 2026-10-27 22:38 那次成功（insmod 在 dmesg 443 s = uptime 约 440 s）
TARGET=${TARGET:-410}
echo "=== z17s-late start $(date) uptime=$(cut -d. -f1 /proc/uptime) TARGET=$TARGET KO=$KO PONLY=$PONLY ==="
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$TARGET" ]; do sleep 5; done
echo "=== 到达 TARGET，uptime=$(cut -d. -f1 /proc/uptime)，启动 z17s-up ==="
exec sh /root/z17s-up.sh
