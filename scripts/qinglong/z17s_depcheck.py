#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Z17S 依赖自检（Python 侧）—— 在青龙容器里把 Python 依赖真跑一遍

用法（青龙面板 → 新建任务 → 任务命令填）：
    task z17s_depcheck.py
建议定时：0 35 9 * * *   （每天 09:35）

同样是 require + 真调用的原则：不听 pip3 list 的标签，逐个 import 并实际用一次。
"""

import os
import sys
import json
import time
import socket
import hashlib
import platform
import subprocess
from datetime import datetime

SCRIPT_DIR = "/ql/data/scripts"
T0 = time.time()
results = []


def rec(kind, name, ok, detail):
    results.append((kind, name, bool(ok), str(detail).replace("\n", " ")[:96]))
    print("[%s] %-8s %-14s %s" % ("PASS" if ok else "FAIL", kind, name, detail))


def attempt(kind, name, fn):
    try:
        d = fn()
        rec(kind, name, True, "ok" if d is None else d)
    except Exception as e:
        rec(kind, name, False, "%s: %s" % (type(e).__name__, e))


print("=" * 78)
print("Z17S 依赖自检（Python）  ·  " + datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
print("=" * 78)
print("python    : %s" % sys.version.split()[0])
print("executable: %s" % sys.executable)
dep_paths = [p for p in sys.path if "dep_cache" in p or "site-packages" in p]
print("site path : %s" % (", ".join(dep_paths) if dep_paths else "(仅系统路径)"))
print("")

print("--- 1. Python 依赖（import + 实际调用） ---")

def _requests():
    t = time.time()
    r = __import__("requests").get("https://registry.npmjs.org/", timeout=15)
    return "HTTP %d  %.0fms  %s" % (r.status_code, (time.time() - t) * 1000, r.headers.get("content-type", "")[:30])


attempt("python", "requests", _requests)


def _crypto_test():
    from Crypto.Hash import SHA256, MD5
    from Crypto.Cipher import AES
    from Crypto.Random import get_random_bytes

    h = SHA256.new(b"z17s-depcheck").hexdigest()[:16]
    key = get_random_bytes(16)
    cipher = AES.new(key, AES.MODE_GCM)
    ct, tag = cipher.encrypt_and_digest("青龙依赖自检".encode("utf-8"))
    plain = AES.new(key, AES.MODE_GCM, nonce=cipher.nonce).decrypt_and_digest(ct, tag)[0]
    assert plain.decode("utf-8") == "青龙依赖自检", "AES 往返不一致"
    return "SHA256=%s…  AES-GCM 往返一致" % h


attempt("python", "Crypto", _crypto_test)


def _stdlib_roundtrip():
    import gzip
    import base64
    import sqlite3
    import tempfile

    raw = "青龙 z17s 依赖自检" * 10
    packed = gzip.compress(raw.encode("utf-8"))
    assert gzip.decompress(packed).decode("utf-8") == raw, "gzip 往返失败"

    fd, p = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(p)
    con.execute("create table t(a int, b text)")
    con.executemany("insert into t values(?,?)", [(1, "x"), (2, "y")])
    con.commit()
    n = con.execute("select count(*) from t").fetchone()[0]
    con.close()
    os.unlink(p)
    assert n == 2
    return "gzip %dB + sqlite %d 行，标准库正常" % (len(packed), n)


attempt("python", "标准库", _stdlib_roundtrip)

print("")
print("--- 2. 缺失的常用包（按需再装） ---")
MISSING_HINT = {
    "Pillow": "图片处理（PIL）",
    "numpy": "数值计算",
    "pandas": "数据分析",
    "prettytable": "表格输出",
    "bs4": "HTML 解析",
    "lxml": "XML 解析",
    "matplotlib": "绘图",
    "pytz": "时区",
}
for mod, desc in MISSING_HINT.items():
    try:
        __import__(mod)
        rec("missing", mod, True, "已安装")
    except ImportError:
        rec("missing", mod, False, "未安装 —— 需要时 pip3 install %s（%s）" % (mod, desc))

print("")
print("--- 3. 系统与网络 ---")

attempt("host", "内核", lambda: "%s %s" % (platform.release(), platform.machine()))


def _distro():
    try:
        return platform.freedesktop_os_release().get("PRETTY_NAME", "?")
    except Exception:
        try:
            txt = open("/etc/os-release").read()
            return [l for l in txt.split("\n") if l.startswith("PRETTY_NAME=")][0].split("=", 1)[1].strip('"')
        except Exception:
            return "(unknown)"


attempt("host", "发行版", _distro)
attempt("host", "主机名", lambda: socket.gethostname())
attempt("host", "本地 IP", lambda: ", ".join(sorted({a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)})) or "(none)")
attempt("host", "负载", lambda: " / ".join("%.2f" % x for x in os.getloadavg()))
attempt("host", "运行时长", lambda: "%.0f 分钟" % (float(open("/proc/uptime").read().split()[0]) / 60))


def _gcc():
    out = subprocess.check_output(["g++", "--version"], timeout=20).decode().split("\n")[0]
    src = "/tmp/z17s_py_check.cpp"
    with open(src, "w") as f:
        f.write('#include <cstdio>\nint main(){ printf("cpp-from-python-ok\\n"); return 0; }\n')
    subprocess.check_output(["g++", "-O2", "-o", "/tmp/z17s_py_check", src], timeout=60)
    run = subprocess.check_output(["/tmp/z17s_py_check"], timeout=10).decode().strip()
    return "%s / 编译运行: %s" % (out, run)


attempt("linux", "g++ 联动", _gcc)


def _dns():
    import socket as s

    ip = s.gethostbyname("registry.npmjs.org")
    return "registry.npmjs.org → %s" % ip


attempt("network", "DNS", _dns)

# ---------------------------------------------------------------- 汇总
print("")
print("--- 4. 汇总 ---")
width = [max(len(str(r[i])) for r in results + [("类别", "项目", "结果", "说明")]) for i in range(4)]
total_w = sum(width) + 3 * 3 + 4
line = "-" * total_w
print(line)
print("| %-*s | %-*s | %-*s | %-*s |" % (width[0], "类别", width[1], "项目", width[2], "结果", width[3], "说明"))
print(line)
for r in results:
    print("| %-*s | %-*s | %-*s | %-*s |" % (width[0], r[0], width[1], r[1], width[2], "PASS" if r[2] else "FAIL", width[3], r[3]))
print(line)

passed = sum(1 for r in results if r[2])
failed = len(results) - passed
missing = sum(1 for r in results if r[0] == "missing" and not r[2])
print("")
print("=" * 78)
print("合计 %d 项：PASS %d  /  FAIL %d（其中 %d 项为未安装的可选包）" % (len(results), passed, failed, missing))
print("耗时 %.1fs" % (time.time() - T0))
print("=" * 78)

report = ["Z17S Python 依赖自检报告  %s" % datetime.now().isoformat()]
report += ["%s\t%s\t%s\t%s" % ("PASS" if r[2] else "FAIL", r[0], r[1], r[3]) for r in results]
report.append("合计 %d：PASS %d / FAIL %d" % (len(results), passed, failed))
with open(os.path.join(SCRIPT_DIR, "z17s-depcheck-py-report.txt"), "w") as f:
    f.write("\n".join(report) + "\n")

sys.exit(1 if (failed - missing) > 0 else 0)
