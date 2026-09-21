#!/usr/bin/env bash
# install-logwatch.sh —— 在设备上部署日志守护（幂等，可反复跑）
#
#   usage: bash scripts/install-logwatch.sh [仓库根目录]
#
# 做四件事：
#   1. 装 z17s-logwatch.py  -> /usr/local/sbin（剥掉 CR，避免 CRLF 破坏 shebang）
#   2. 装 z17s-logwatch.service -> /etc/systemd/system
#   3. 装 journald 覆盖 10-z17s.conf -> /etc/systemd/journald.conf.d
#   4. daemon-reload / journald restart / enable --now logwatch，然后验证
#
# 设计原则：不挂启动关键路径（踩过 z17s-usbnet 拖死开机的坑），
#           journald 覆盖写错参数名不致命但要当场看日志确认。

set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
DEV="$SRC/device"

if [ ! -d "$DEV" ]; then
  echo "FATAL: device tree not found: $DEV" >&2
  exit 1
fi

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. 装文件
say "1/4 安装文件"

install_one() {
  local rel="$1" mode="$2"
  local src="$DEV/$rel"
  local dst="/$rel"
  if [ ! -f "$src" ]; then
    echo "  SKIP (missing): $rel" >&2
    return
  fi
  install -D -m "$mode" /dev/null "$dst"
  # tr 掉 CR：CRLF 会让 shebang 变成 "#!/usr/bin/env python3\r" 而执行失败
  tr -d '\r' < "$src" > "$dst"
  chmod "$mode" "$dst"
  printf '  %-58s mode=%s\n' "$dst" "$mode"
}

install_one "usr/local/sbin/z17s-logwatch.py"          755
install_one "usr/local/sbin/z17s-screendump"           755
install_one "etc/systemd/system/z17s-logwatch.service" 644
install_one "etc/systemd/journald.conf.d/10-z17s.conf" 644

mkdir -p /var/log/z17s-kmsg
chmod 755 /var/log/z17s-kmsg

# 语法自检：Python 编译不过就别往下走了
say "1b   Python 语法自检"
if python3 -m py_compile /usr/local/sbin/z17s-logwatch.py; then
  echo "  OK: py_compile passed"
  rm -rf /usr/local/sbin/__pycache__
else
  echo "  FATAL: py_compile failed" >&2
  exit 1
fi

# ---------------------------------------------------------------- 2. journald
say "2/4 应用 journald 覆盖"
systemctl restart systemd-journald
journalctl --flush >/dev/null 2>&1 || true
sleep 1
echo "--- 有效配置（只看非默认项）---"
systemctl cat systemd-journald >/dev/null 2>&1
if command -v systemd-analyze >/dev/null 2>&1; then
  # 注意 pipefail：grep 无匹配会返回非零并让整个脚本退出，必须兜底
  { grep -E '^\s*(Storage|SyncIntervalSec|SystemMaxUse|RateLimitBurst)' \
      /etc/systemd/journald.conf.d/10-z17s.conf | sed 's/^/  /' ; } || true
fi
echo "--- journald 自身有没有抱怨未知键 ---"
journalctl -b -u systemd-journald -n 30 --no-pager 2>/dev/null \
  | grep -iE 'unknown|ignoring|invalid' | sed 's/^/  /' || echo "  (none)"

# ---------------------------------------------------------------- 3. 服务
say "3/4 启动 z17s-logwatch"
systemctl daemon-reload
systemctl enable z17s-logwatch >/dev/null 2>&1 || true
systemctl restart z17s-logwatch
sleep 3

# ---------------------------------------------------------------- 4. 验证
say "4/4 验证"
systemctl --no-pager --full status z17s-logwatch | head -14 || true

echo
echo "--- 产物 ---"
ls -la /var/log/z17s-kmsg/ | sed 's/^/  /'

echo
echo "--- 日志开头 ---"
head -c 600 /var/log/z17s-kmsg/latest 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"

echo
echo "--- 心跳（等 12 秒）---"
sleep 12
# ⚠️ 必须扫内核消息全量：不能加 -n，1Panel/docker 的日志刷得太快，
#    200 条窗口里根本轮不到"每 10 秒才一条"的心跳（曾因此误报"心跳没起来"）
if journalctl -b -k --no-pager 2>/dev/null | grep -q 'z17s-hb'; then
  journalctl -b -k --no-pager 2>/dev/null | grep 'z17s-hb' | tail -3 | sed 's/^/  /'
  echo "  -> 心跳 OK。PC 侧串口记录器应每 10 秒看到一行 z17s-hb"
  echo "     （直写 /dev/ttyGS0，所以**没有** [ 1234.567890] 这种内核时间戳前缀 —— 那是 printk 的特征）"
else
  echo "  !! 12 秒内没看到 z17s-hb，检查： journalctl -u z17s-logwatch -n 50"
fi

echo
echo "--- 屏幕是否干净（心跳不该再刷屏）---"
if [ -c /dev/vcsa1 ] && [ -x /usr/local/sbin/z17s-screendump ]; then
  /usr/local/sbin/z17s-screendump -n 4 2>/dev/null | sed 's/^/  /' || true
  # 头部 2 行是工具自己的标题，之后才是屏幕内容；干净时应只剩 Debian 横幅 + login:
  nz="$(/usr/local/sbin/z17s-screendump -n 0 2>/dev/null | tail -n +3 | grep -c . || true)"
  nz="${nz:-0}"
  if [ "$nz" -le 6 ]; then
    echo "  -> 屏幕干净（非空 ${nz} 行）✔"
  else
    echo "  !! 屏幕有 ${nz} 行非空内容 —— 有东西在往 console 写，查 z17s-hb 或内核报错"
  fi
else
  echo "  (跳过：无 /dev/vcsa1 或无 z17s-screendump)"
fi

echo
echo "INSTALL_DONE"
