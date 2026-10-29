#!/bin/sh
# 在设备上构建并安装 DbusSmsForwardCPlus（含 Z17S 补丁）
#   用法： sh install-dbussms.sh [端口]        默认端口 1102
#   前提： 已装 ModemManager、能 `mmcli -L` 看到模组
set -e

PORT=${1:-1102}
DEST=/root/sms
SRC=/tmp/dbussms-build

say() { echo "== $*" >&2; }

say "[1] 安装编译依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    g++ libdbus-1-dev libssl-dev libcurl4-openssl-dev pkg-config

say "[2] 取源码 + 打补丁"
rm -rf "$SRC"; mkdir -p "$SRC"; cd "$SRC"
curl -sL -o r.zip "https://codeload.github.com/lkiuyu/DbusSmsForwardCPlus/zip/refs/heads/master"
unzip -q r.zip
cd DbusSmsForwardCPlus-master/DbusSmsForwardCPlus
# 上游是 CRLF，补丁按 LF 生成，先统一
find . -name '*.cpp' -o -name '*.h' | while read -r f; do sed -i 's/\r$//' "$f"; done
patch -p1 < "$(dirname "$0")/z17s-dbussms.patch"

say "[3] 编译"
g++ -O2 -std=gnu++17 -Wno-error=format-security -Wno-unused-parameter \
    -Wno-sign-compare -Wno-missing-field-initializers -Wno-mismatched-new-delete \
    $(pkg-config --cflags dbus-1 libcurl openssl) \
    main.cpp mail.cpp -o DbusSmsForwardCPlus \
    $(pkg-config --libs dbus-1 libcurl openssl) -lpthread

say "[4] 部署到 $DEST"
mkdir -p "$DEST"
cp -f DbusSmsForwardCPlus "$DEST/DbusSmsForwardCPlus"
chmod 755 "$DEST/DbusSmsForwardCPlus"

if [ ! -f "$DEST/config.txt" ]; then
    cp -f "$(dirname "$0")/config.txt" "$DEST/config.txt"
    sed -i "s/^apiPort = .*/apiPort = $PORT/" "$DEST/config.txt"
else
    say "    已有 config.txt，保留原配置（端口以文件内 apiPort 为准）"
fi

cp -f "$(dirname "$0")/forward.sh" "$DEST/forward.sh"
chmod 755 "$DEST/forward.sh"

# 企业微信转发（key 单独存 600，不进仓库）
cp -f "$(dirname "$0")/wecom.py" "$DEST/wecom.py"
chmod 755 "$DEST/wecom.py"
if [ ! -f "$DEST/webhook.conf" ]; then
    if [ -f "$(dirname "$0")/webhook.conf" ]; then
        cp -f "$(dirname "$0")/webhook.conf" "$DEST/webhook.conf"
    else
        cp -f "$(dirname "$0")/webhook.conf.example" "$DEST/webhook.conf"
        say "    !! 请编辑 $DEST/webhook.conf 填入 WECOM_KEY（不填则只落盘不转发）"
    fi
    chmod 600 "$DEST/webhook.conf"
else
    say "    已有 webhook.conf，保留原 key"
fi

say "[5] 安装 systemd 单元"
cp -f "$(dirname "$0")/dbussms.service" /etc/systemd/system/dbussms.service
# 掉网期间没发出去的短信，靠这个定时器每 5 min 补发一次
cp -f "$(dirname "$0")/z17s-sms-replay.service" /etc/systemd/system/z17s-sms-replay.service
cp -f "$(dirname "$0")/z17s-sms-replay.timer" /etc/systemd/system/z17s-sms-replay.timer
chmod 644 /etc/systemd/system/dbussms.service \
           /etc/systemd/system/z17s-sms-replay.service \
           /etc/systemd/system/z17s-sms-replay.timer
systemctl daemon-reload
systemctl enable --now dbussms.service
systemctl enable --now z17s-sms-replay.timer
sleep 2
systemctl is-active dbussms.service
systemctl is-enabled z17s-sms-replay.timer
ss -lntp 2>/dev/null | grep ":$PORT" || say "    !! 端口 $PORT 未监听，看 journalctl -u dbussms"

say "完成： http://<设备IP>:$PORT/"
say "  转发记录： $DEST/sms.log"
say "  运行日志： $DEST/run.log"
say "  转发结果： $DEST/forward.log（带时间戳）"
say "  待补发队列： $DEST/wecom-pending.jsonl（正常为空）"
