#!/bin/sh
# DbusSmsForwardCPlus shell 转发钩子
# $1=发信号码  $2=收信时间  $3=短信内容  $4=验证码  $5=验证码来源  $6=设备名
NUM="$1"; DATE="$2"; TEXT="$3"; CODE="$4"; CODEFROM="$5"; DEV="$6"

LOG=/root/sms/sms.log
printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$NUM" "$CODE" "$DEV" "$TEXT" >> "$LOG"

# ── 需要推到别处就在下面加一行，例如 ──────────────────────────────
# Telegram:
# curl -s --max-time 10 "https://api.telegram.org/bot<TOKEN>/sendMessage" \
#   --data-urlencode "chat_id=<CHAT_ID>" \
#   --data-urlencode "text=[$DEV] $NUM ($DATE)
# $TEXT" >/dev/null
#
# Bark:
# curl -s --max-time 10 "https://api.day.app/<KEY>/$NUM/$TEXT" >/dev/null
#
# 企业微信机器人:
# curl -s --max-time 10 -H 'Content-Type: application/json' \
#   -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[$DEV] $NUM\n$TEXT\"}}" \
#   "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<KEY>" >/dev/null
# ─────────────────────────────────────────────────────────────
exit 0
