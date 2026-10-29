#!/bin/sh
# DbusSmsForwardCPlus shell 转发钩子
# $1=发信号码  $2=收信时间  $3=短信内容  $4=验证码  $5=验证码来源  $6=设备名
NUM="$1"; DATE="$2"; TEXT="$3"; CODE="$4"; CODEFROM="$5"; DEV="$6"

# 1) 本地留档
printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$NUM" "$CODE" "$DEV" "$TEXT" >> /root/sms/sms.log

# 2) 推到企业微信群机器人（key 在 /root/sms/webhook.conf，不进仓库）
/usr/bin/python3 /root/sms/wecom.py "$NUM" "$DATE" "$TEXT" "$CODE" "$CODEFROM" "$DEV" \
    >> /root/sms/forward.log 2>&1

exit 0
