#!/usr/bin/env python3
# 企业微信群机器人转发 —— 由 DbusSmsForwardCPlus 的 shell 钩子调用
#
# 用法:
#   wecom.py <号码> <时间> <内容> <验证码> <验证码来源> <设备名>   正常转发
#   wecom.py --replay                                            重放积压（补发）
#
# 为什么要重试：开机后蜂窝要 ~172 s 才拿到 IP，Wi-Fi 也可能在漫游。
# 这期间来的短信，第一次 POST 必然失败。原来直接放弃 = 群里永远收不到这条。
# 现在重试 3 次（0/3/10 s 退避），仍失败就落到 PENDING_FILE，等 --replay 补发。
import json, os, sys, time, urllib.request

KEY_FILE = "/root/sms/webhook.conf"
PENDING_FILE = "/root/sms/wecom-pending.jsonl"
DELAYS = (0, 3, 10)          # 三次尝试之间的等待秒数
TIMEOUT = 10


def log(msg, err=False):
    """带时间戳写 forward.log，方便和 sms.log 对账。"""
    print("[%s] %s" % (time.strftime("%F %T"), msg),
          file=sys.stderr if err else sys.stdout)


def load_key():
    # 允许用环境变量临时覆盖，方便自测（不落盘、不影响正常转发）
    env = os.environ.get("WECOM_KEY", "").strip()
    if env:
        return env
    try:
        with open(KEY_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("WECOM_KEY="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return ""


def post(url, data):
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8"))


def send(content, key):
    """返回 (ok, 描述)。失败时描述里带原因，便于看 forward.log。"""
    body = {"msgtype": "text", "text": {"content": content}}
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=" + key

    reason = ""
    for i, delay in enumerate(DELAYS):
        if delay:
            time.sleep(delay)
        try:
            resp = post(url, data)
        except Exception as e:
            reason = "请求失败 %s" % e
            continue
        if resp.get("errcode") == 0:
            if i:
                return True, "ok（第 %d 次尝试成功）" % (i + 1)
            return True, "ok"
        reason = "接口返回 %s" % resp
    return False, reason


def build_text(num, date, text, code, dev):
    lines = ["【%s】收到短信" % (dev or "Z17S")]
    lines.append("号码：%s" % num)
    if date:
        lines.append("时间：%s" % date)
    if code:
        lines.append("验证码：%s" % code)
    lines.append("内容：")
    lines.append(text)
    return "\n".join(lines)


def spool(content, reason):
    """落盘待补发。一行一个 JSON，--replay 逐条重试。"""
    try:
        with open(PENDING_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": time.strftime("%F %T"), "content": content,
                                "reason": reason}, ensure_ascii=False) + "\n")
        os.chmod(PENDING_FILE, 0o600)
    except Exception as e:
        log("wecom: 写待补发队列失败 %s" % e, err=True)


def replay(key):
    """补发积压；成功的从队列里删掉，失败的留着。"""
    if not os.path.exists(PENDING_FILE):
        log("replay: 队列为空")
        return 0
    keep, ok_n, fail_n = [], 0, 0
    with open(PENDING_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            good, reason = send(item.get("content", ""), key)
            if good:
                ok_n += 1
            else:
                fail_n += 1
                item["reason"] = reason
                keep.append(item)
    tmp = PENDING_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for item in keep:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    if keep:
        os.replace(tmp, PENDING_FILE)
    else:
        os.remove(tmp)
        os.remove(PENDING_FILE)
    log("replay: 成功 %d，仍失败 %d" % (ok_n, fail_n))
    return 0 if fail_n == 0 else 5


def main():
    key = load_key()
    if not key:
        log("wecom: WECOM_KEY 未配置（%s）" % KEY_FILE, err=True)
        return 2

    if len(sys.argv) > 1 and sys.argv[1] == "--replay":
        return replay(key)

    args = (sys.argv[1:7] + [""] * 6)[:6]
    num, date, text, code, codefrom, dev = args
    content = build_text(num, date, text, code, dev)

    good, reason = send(content, key)
    if good:
        log("wecom: %s" % reason)
        return 0

    log("wecom: %s" % reason, err=True)
    spool(content, reason)
    log("wecom: 已落待补发队列 %s" % PENDING_FILE, err=True)
    return 3


if __name__ == "__main__":
    sys.exit(main())
