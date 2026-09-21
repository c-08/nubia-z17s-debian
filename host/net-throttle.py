#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
net-throttle.py —— 管道限速器（纯标准库，Windows / Linux 通用）

用途：串在 PC 侧的 SSH 管道里，给「设备 → PC」的数据流限速。
      PC 侧限速会通过 TCP 反压让设备端的 tar 也跟着慢下来，
      从而避免把 USB/RNDIS 通路压到饱和。

    ssh z17s 'tar ...' | python net-throttle.py --rate 2m | gzip -1 > out.tar.gz

为什么需要它：2026-09-21 实测，设备侧 `tar -C / -cf - . > /dev/null`（纯读盘，
不走网络）能完整跑完；但同样的 tar 走 SSH/RNDIS 把上 GB 数据推出去时，
设备会在 2 分钟量级整机硬卡死（RCU stall）。怀疑是「大量存储读 + USB 持续满载」
叠加触发。限速是目前最便宜的对策。

用法：
    python net-throttle.py --rate 2m       # 约 2 MiB/s
    python net-throttle.py --rate 800k     # 约 800 KiB/s
    python net-throttle.py --rate 0        # 不限速（直通）
"""

import argparse
import os
import sys
import time

BLOCK = 65536


def parse_rate(text):
    """把 '2m' / '800k' / '1.5M' / '0' 解析成字节/秒。"""
    s = str(text).strip().lower()
    if not s:
        raise ValueError("空速率")
    mult = 1
    if s.endswith("k"):
        mult, s = 1024, s[:-1]
    elif s.endswith("m"):
        mult, s = 1024 * 1024, s[:-1]
    elif s.endswith("g"):
        mult, s = 1024 ** 3, s[:-1]
    return float(s) * mult


def main():
    ap = argparse.ArgumentParser(description="管道限速器（stdin → stdout）")
    ap.add_argument("--rate", default="2m",
                    help="目标速率，如 2m / 800k / 0（0 = 不限速），默认 2m")
    ap.add_argument("--quiet", action="store_true", help="不往 stderr 打统计")
    args = ap.parse_args()

    rate = parse_rate(args.rate)

    # Windows 上必须走二进制 buffer，否则会把 \\n 逐字节改写、破坏归档
    inp = getattr(sys.stdin, "buffer", sys.stdin)
    out = getattr(sys.stdout, "buffer", sys.stdout)

    if rate <= 0:
        # 直通模式：仍在 Python 里过一遍，便于统一行为
        total = 0
        while True:
            b = inp.read(BLOCK)
            if not b:
                break
            out.write(b)
            out.flush()
            total += len(b)
        if not args.quiet:
            sys.stderr.write("\n[net-throttle] 直通模式，共 %d 字节\n" % total)
        return 0

    start = time.monotonic()
    total = 0
    last_report = start

    try:
        while True:
            b = inp.read(BLOCK)
            if not b:
                break
            out.write(b)
            out.flush()
            total += len(b)

            # 平均速率控制：落后目标进度就睡一会儿
            target = start + total / rate
            now = time.monotonic()
            if target > now:
                time.sleep(target - now)
                now = time.monotonic()

            if not args.quiet and now - last_report >= 5.0:
                elapsed = now - start
                sys.stderr.write("\r[net-throttle] %.1f MiB / %.0fs (%.2f MiB/s)"
                                 % (total / 1048576.0, elapsed,
                                    total / 1048576.0 / max(elapsed, 1e-6)))
                sys.stderr.flush()
                last_report = now
    except (BrokenPipeError, KeyboardInterrupt):
        pass

    if not args.quiet:
        elapsed = time.monotonic() - start
        sys.stderr.write("\n[net-throttle] 完成：%.1f MiB / %.0fs (平均 %.2f MiB/s)\n"
                         % (total / 1048576.0, elapsed,
                            total / 1048576.0 / max(elapsed, 1e-6)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
