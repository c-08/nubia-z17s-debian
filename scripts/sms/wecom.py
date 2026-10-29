#!/usr/bin/env python3
# 企业微信群机器人转发 —— 由 DbusSmsForwardCPlus 的 shell 钩子调用
# 用法: wecom.py <号码> <时间> <内容> <验证码> <验证码来源> <设备名>
import json, os, sys, urllib.request

KEY_FILE = "/root/sms/webhook.conf"


def load_key():
    try:
        with open(KEY_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("WECOM_KEY="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return ""


def main():
    args = (sys.argv[1:7] + [""] * 6)[:6]
    num, date, text, code, codefrom, dev = args

    key = load_key()
    if not key:
        print("wecom: WECOM_KEY 未配置（%s）" % KEY_FILE, file=sys.stderr)
        return 2

    lines = ["【%s】收到短信" % (dev or "Z17S")]
    lines.append("号码：%s" % num)
    if date:
        lines.append("时间：%s" % date)
    if code:
        lines.append("验证码：%s" % code)
    lines.append("内容：")
    lines.append(text)

    body = {"msgtype": "text", "text": {"content": "\n".join(lines)}}
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=" + key
    req = urllib.request.Request(url, data=data,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            resp = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        print("wecom: 请求失败 %s" % e, file=sys.stderr)
        return 3

    if resp.get("errcode") != 0:
        print("wecom: 接口返回 %s" % resp, file=sys.stderr)
        return 4
    print("wecom: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
