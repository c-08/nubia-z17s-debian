#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
z17s-logwatch —— 内核日志低延迟落盘 + 存活心跳 + 现场快照

为什么不能只靠 journald：
  1. journald 的 SyncIntervalSec 默认 300s —— 强断电（长按电源）最多丢 5 分钟日志；
  2. journald 有速率限流，崩溃风暴（如 WCN3990 MSS crash 刷屏）时静默丢消息；
  3. RCU stall / 关中断死等时用户态进程完全不被调度 —— 此刻 journald 也停摆，
     实测 09-21 那次卡死，journald 一条都没写进去，证据只剩屏幕照片。
     本脚本把"最后一条写盘记录"压到 0.25 秒以内，至少保住停摆前那一刻；
  4. 每 10 秒往 USB gadget 串口（/dev/ttyGS0）直写一条心跳，重启后看它断在哪一秒，
     就知道卡死发生的确切时刻 —— 不依赖任何用户态工具。

     ⚠️ 心跳**刻意不走 /dev/kmsg**。本机 cmdline 是
        `console=tty0 console=ttyGS0,115200n8`，手机屏幕 tty0 也是内核 console，
        而 printk 会把同一条消息广播给**所有** console —— 于是屏幕被心跳刷满，
        还把 tty1 上跑着的 agetty 登录提示符永久冲掉，用户据此误判"设备卡死"。
        直写 ttyGS0 只喂串口，屏幕立刻恢复干净；kmsg 侧另留一条 <7> 级副本：
        它照样进 journal 与本站日志文件，但 console_loglevel=4 会把它挡在屏幕之外。

     ⚠️ 直写串口必须 O_NONBLOCK：PC 侧没人读串口时缓冲区会满，阻塞写会拖死本进程
        （与 §7.1 "串口写阻塞拖死 systemd PID1" 是同一类雷）。非阻塞下写不进去就丢弃。
     环境变量 Z17S_HB_TTY 可覆盖出口；设成空串则退回旧行为（走 kmsg KERN_ERR 上屏）。

注意（不要对它抱幻想）：整机真正停摆时，本进程同样得不到调度，一样写不进去。
那种场景唯一的取证途径是 PC 侧持续录串口（host/windows/serial/z17s-serial-log.ps1）。

用法：
    python3 /usr/local/sbin/z17s-logwatch.py          # 前台
    systemctl enable --now z17s-logwatch              # 服务方式

产物（默认 LOG_DIR=/var/log/z17s-kmsg）：
    kmsg-<bootid8>-<启动时间>.log   内核日志，单文件 16MB，保留最近 12 个
    snapshot-<bootid8>.log          每 60s 一份现场快照（mem/CPU/D 状态任务/USB）
    boots.tsv                       每次开机登记一行
    latest                          指向当前日志的符号链接
"""

import errno
import glob
import os
import signal
import subprocess
import sys
import time

KMSG = "/dev/kmsg"
LOG_DIR = "/var/log/z17s-kmsg"

# 心跳出口。默认直写 USB gadget 串口；设 Z17S_HB_TTY= (空) 退回旧行为（kmsg KERN_ERR 上屏）
HB_TTY = os.environ.get("Z17S_HB_TTY", "/dev/ttyGS0").strip()
# kmsg 里的心跳级别：有串口出口时用 DEBUG(7) —— 进 journal/文件但不上 console；
# 没有串口出口时退回 ERR(3) —— 靠 printk 广播出去
HB_LEVEL = 7 if HB_TTY else 3

POLL_SEC = 0.1                 # 轮询间隔
FLUSH_SEC = 0.25               # 最长多久强制 fsync 一次
FLUSH_BYTES = 8192             # 或攒够这么多字节就 fsync
HB_SEC = 10                    # 心跳周期
SNAP_SEC = 60                  # 快照周期
MAX_BYTES = 16 * 1024 * 1024   # 单日志文件上限
KEEP_FILES = 12                # 保留几个历史日志
MAX_PENDING = 4 * 1024 * 1024  # 积压上限，超出丢最旧的
MIN_FREE_BYTES = 200 * 1024 * 1024   # 根分区低于此值就开始清旧日志

_running = True


def _on_signal(signum, frame):
    global _running
    _running = False


def read_text(path, default=""):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except Exception:
        return default


def now_iso():
    lt = time.localtime()
    return time.strftime("%Y-%m-%dT%H:%M:%S", lt) + time.strftime("%z", lt)


def uptime_sec():
    try:
        return float(read_text("/proc/uptime", "0 0").split()[0])
    except Exception:
        return 0.0


def boot_id():
    return read_text("/proc/sys/kernel/random/boot_id", "unknown").strip() or "unknown"


class LogWatch(object):
    def __init__(self):
        self.bid = boot_id()
        self.short = self.bid.split("-")[0]
        self.path = None
        self.fh = None
        self.snap_path = None
        self.snap_fh = None
        self.buf = bytearray()
        self.last_flush = time.monotonic()
        self.last_hb = 0.0
        self.last_snap = 0.0
        self.last_guard = 0.0
        self.dropped = 0
        self.seq = 0
        self.ser_fd = None          # 心跳串口出口（懒打开，失败即重试）

    # ------------------------------------------------------------------ 文件
    def open_log(self):
        # 命名策略：一次开机一个文件（kmsg-<bootid8>.log），服务重启就追加，
        # 只有超过 MAX_BYTES 才递增编号 kmsg-<bootid8>.1.log …
        # 好处：同一 boot 内不会因为 systemctl restart 碎成一堆文件，
        #       而每次开机天然分开，跨重启对比一目了然。
        base = os.path.join(LOG_DIR, "kmsg-%s" % self.short)
        idx = 0
        while True:
            name = "%s.log" % base if idx == 0 else "%s.%d.log" % (base, idx)
            path = os.path.join(LOG_DIR, name)
            if not os.path.exists(path) or os.path.getsize(path) < MAX_BYTES:
                break
            idx += 1
        self.path = path
        # buffering=0 → write() 直接进 syscall，不会被 Python 缓冲挡住
        self.fh = open(path, "ab", buffering=0)
        link = os.path.join(LOG_DIR, "latest")
        try:
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(os.path.basename(self.path), link)
        except OSError:
            pass

    def open_snapshot(self):
        self.snap_path = os.path.join(LOG_DIR, "snapshot-%s.log" % self.short)
        self.snap_fh = open(self.snap_path, "ab", buffering=0)

    def cleanup(self, keep=None):
        keep = KEEP_FILES if keep is None else keep
        files = sorted(glob.glob(os.path.join(LOG_DIR, "kmsg-*.log")), key=os.path.getmtime)
        if len(files) <= keep:
            return
        for old in files[:-keep]:
            try:
                os.unlink(old)
            except OSError:
                pass

    def rotate(self):
        if self.fh is None:
            return
        try:
            size = self.fh.tell()
        except Exception:
            return
        if size < MAX_BYTES:
            return
        self.flush(force=True)
        try:
            self.fh.close()
        except Exception:
            pass
        self.cleanup()
        self.open_log()
        self.write(("[z17s-logwatch] rotated -> %s\n" % os.path.basename(self.path)).encode())

    def guard_space(self):
        try:
            st = os.statvfs(LOG_DIR)
            free = st.f_bavail * st.f_frsize
        except Exception:
            return
        if free < MIN_FREE_BYTES:
            self.write(("[z17s-logwatch] !! low space (%d MB free), pruning old logs !!\n"
                        % (free // 1048576)).encode())
            self.flush(force=True)
            self.cleanup(keep=2)

    # ------------------------------------------------------------------ 写盘
    def write(self, data):
        if not data:
            return
        self.buf += data
        if len(self.buf) > MAX_PENDING:
            over = len(self.buf) - MAX_PENDING // 2
            del self.buf[:over]
            self.dropped += over
            self.buf += ("[z17s-logwatch] !! dropped %d bytes (writer too slow) !!\n"
                         % over).encode()

    def flush(self, force=False):
        if not self.buf:
            return
        if not force and len(self.buf) < FLUSH_BYTES and (time.monotonic() - self.last_flush) < FLUSH_SEC:
            return
        chunk = bytes(self.buf)
        self.buf = bytearray()
        try:
            self.fh.write(chunk)
            os.fdatasync(self.fh.fileno())      # 真正落盘，不是只进 page cache
        except Exception as e:
            sys.stderr.write("z17s-logwatch: write failed: %s\n" % e)
            try:
                sys.stderr.flush()
            except Exception:
                pass
        self.last_flush = time.monotonic()

    def snap_write(self, text):
        if self.snap_fh is None:
            return
        try:
            self.snap_fh.write(text.encode("utf-8", "replace"))
            os.fdatasync(self.snap_fh.fileno())
        except Exception:
            pass

    # ------------------------------------------------------------------ 心跳
    HB_CHILD_TIMEOUT = 2.0       # 子进程写串口最多等这么久，绝不拖住主循环

    @staticmethod
    def _gadget_ready():
        """gadget 有没有被 bind 上。

        2026-09-21 实测：开机 +45s 时 `z17s-usbnet.sh` 会**拆掉并重建**整个 gadget，
        ttyGS0 节点在这一瞬间被销毁重建。此刻往里写 → 内核 tty 层 oops 落到本进程 →
        `z17s-logwatch` 被 SIGSEGV 打死（`status=11/SEGV`，整次开机唯一一条 gs_close 就是它
        的 fd 关掉造成的）。所以写之前先看一眼 gadget 状态，撕设备的窗口里干脆不写。
        读不到 configfs 就当"没有这个机制"，不拦（兼容旧的 g_serial 模式）。
        """
        try:
            base = "/sys/kernel/config/usb_gadget"
            names = os.listdir(base)
        except OSError:
            return True
        try:
            for name in names:
                try:
                    with open(os.path.join(base, name, "UDC")) as fh:
                        if fh.read().strip():
                            return True
                except OSError:
                    continue
            return False
        except Exception:
            return True

    def _write_isolated(self, fd, data):
        """把真正的 write 丢进子进程：崩了只崩子进程，主进程（日志跟随）活着。

        Python 捕不到内核送来的 SIGSEGV，所以唯一可靠的办法是把 syscall 隔离出去。
        返回 True 表示写成功；False 表示失败/被信号打死（调用方应丢弃这个 fd）。
        """
        try:
            pid = os.fork()
        except OSError as e:
            sys.stderr.write("z17s-logwatch: serial hb fork failed: %s\n" % e)
            return False
        if pid == 0:                                   # ---- 子进程 ----
            try:
                os.write(fd, data)
                os._exit(0)
            except BaseException:
                os._exit(1)
        deadline = time.monotonic() + self.HB_CHILD_TIMEOUT
        while time.monotonic() < deadline:             # ---- 父进程 ----
            try:
                wpid, status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return False
            if wpid:
                if os.WIFSIGNALED(status):
                    sys.stderr.write("z17s-logwatch: serial hb killed by signal %d"
                                     " (gadget 撕设备？已丢弃 fd，下次重开)\n" % os.WTERMSIG(status))
                    return False
                return os.WEXITSTATUS(status) == 0
            time.sleep(0.05)
        # 超时：子进程卡在 write 里，杀掉，fd 视为已废（避免复用半死的 fd）
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        sys.stderr.write("z17s-logwatch: serial hb write timed out, fd dropped\n")
        return False

    def serial_write(self, text):
        """直写 USB gadget 串口。

        O_NONBLOCK 是硬要求：PC 侧没读串口时缓冲会满，阻塞写会拖死本进程
        （§7.1 的老雷：串口控制台阻塞曾把 systemd PID1 卡了 82 分钟）。
        非阻塞下写不进去就返回 EAGAIN，我们直接丢弃 —— 心跳丢了无所谓，卡住进程不行。
        """
        data = text.encode("utf-8", "replace")
        if not self._gadget_ready():
            return                       # 正在拆/建 gadget，这一拍跳过
        for attempt in (0, 1):           # 第二次机会：USB 重连后节点会重建，重开一次
            if self.ser_fd is None:
                try:
                    if not os.path.exists(HB_TTY):
                        return
                    self.ser_fd = os.open(HB_TTY, os.O_WRONLY | os.O_NONBLOCK | os.O_NOCTTY)
                    self._tty_raw(self.ser_fd)
                except OSError as e:
                    self.ser_fd = None
                    if attempt:
                        sys.stderr.write("z17s-logwatch: serial hb open failed: %s\n" % e)
                    return
            if self._write_isolated(self.ser_fd, data):
                return
            try:
                os.close(self.ser_fd)
            except OSError:
                pass
            self.ser_fd = None
            if not self._gadget_ready():
                return

    @staticmethod
    def _tty_raw(fd):
        """关掉 ONLCR / ECHO：否则写入的 \\n 会被 tty 层改成 \\r\\n，串口日志里
        一片多余的 CR（内核 console 直出时没有这个转换）。失败无所谓。"""
        try:
            import termios
            attrs = termios.tcgetattr(fd)
            attrs[1] &= ~termios.ONLCR       # oflag
            attrs[3] &= ~termios.ECHO        # lflag
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        except Exception:
            pass

    def heartbeat(self):
        up = uptime_sec()
        la = "/".join(read_text("/proc/loadavg").split()[:3]) or "?"
        # 1) 落到自己的日志文件（证明本进程还活着）
        self.write(("[z17s-hb] %s uptime=%.0fs load=%s file=%s\n"
                    % (now_iso(), up, la, os.path.basename(self.path or "-"))).encode())
        line = "z17s-hb uptime=%.0f load=%s\n" % (up, la)
        # 2) 只喂串口 —— 不走 printk，屏幕才不会被刷屏
        if HB_TTY:
            self.serial_write(line)
        # 3) kmsg 留副本：默认 DEBUG 级，进 journal 与本站日志文件，但上不了 console
        try:
            with open(KMSG, "wb", buffering=0) as fh:
                fh.write(("<%d>%s" % (HB_LEVEL, line)).encode("utf-8", "replace"))
        except Exception:
            pass

    # ------------------------------------------------------------------ 快照
    def snapshot(self):
        out = []
        ap = out.append
        ap("=" * 74)
        ap("[z17s-snap] %s uptime=%.0fs" % (now_iso(), uptime_sec()))
        ap("loadavg : " + read_text("/proc/loadavg").strip())
        wanted = ("MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached",
                  "Dirty", "Writeback", "SwapFree")
        for ln in read_text("/proc/meminfo").splitlines():
            if ln.split(":")[0] in wanted:
                ap("mem     : " + ln.strip())
        ap("--- per-cpu jiffies (user nice sys idle iowait irq softirq) ---")
        for ln in read_text("/proc/stat").splitlines():
            if ln.startswith("cpu"):
                ap("stat    : " + ln.strip())
        # D 状态（不可中断睡眠）任务 —— 卡死时看谁挂在哪个内核函数
        ap("--- D-state tasks (uninterruptible) ---")
        found = False
        try:
            for d in sorted(os.listdir("/proc")):
                if not d.isdigit():
                    continue
                try:
                    st = read_text("/proc/%s/stat" % d)
                    rp = st.rindex(")")
                    fields = st[rp + 2:].split()
                    if not fields or fields[0] != "D":
                        continue
                    comm = st[st.index("(") + 1:rp]
                    wchan = read_text("/proc/%s/wchan" % d).strip()
                    ap("D-task  : pid=%-6s comm=%-18s wchan=%s" % (d, comm, wchan))
                    found = True
                except Exception:
                    continue
        except Exception:
            pass
        if not found:
            ap("D-task  : (none)")
        # 中断计数（USB / MSS / 定时器）
        ap("--- interrupts (msm/dwc3/qcom) ---")
        for ln in read_text("/proc/interrupts").splitlines()[1:]:
            low = ln.lower()
            if any(k in low for k in ("dwc3", "usb", "msm", "q6", "timer", "arch_timer")):
                ap("irq     : " + " ".join(ln.split()))
        ap("--- usb gadget / net ---")
        for udc in glob.glob("/sys/class/udc/*"):
            ap("udc     : %s state=%s" % (os.path.basename(udc),
                                          read_text(os.path.join(udc, "state")).strip() or "?"))
        ap("usb0    : " + (read_text("/sys/class/net/usb0/operstate").strip() or "?"))
        for ln in read_text("/proc/net/dev").splitlines():
            if "usb0" in ln:
                ap("netdev  : " + " ".join(ln.split()))
        ap("")
        self.snap_write("\n".join(out) + "\n")

    # ------------------------------------------------------------------ 读 kmsg
    @staticmethod
    def fmt(raw):
        """<prio>,<seq>,<usec>,<flags>;<message> -> [  123.456789] <prio> message"""
        try:
            meta, _, msg = raw.partition(b";")
            prio, _seq, usec, _flags = meta.split(b",")
            text = "[%13.6f] <%s> %s" % (int(usec) / 1e6, prio.decode(),
                                         msg.decode("utf-8", "replace"))
            if not text.endswith("\n"):
                text += "\n"
            return text.encode("utf-8", "replace")
        except Exception:
            if not raw.endswith(b"\n"):
                raw += b"\n"
            return raw

    def pump(self, fd):
        for _ in range(8192):
            try:
                raw = os.read(fd, 65536)
            except BlockingIOError:
                return
            except OSError as e:
                if e.errno == errno.EPIPE:
                    self.write(b"[z17s-logwatch] !! EPIPE: ring buffer overwritten, gap in log !!\n")
                else:
                    self.write(("[z17s-logwatch] !! kmsg read error: %s !!\n" % e).encode())
                return
            if not raw:
                return
            self.seq += 1
            self.write(self.fmt(raw))

    def tick(self):
        now = time.monotonic()
        if self.buf and (len(self.buf) >= FLUSH_BYTES or (now - self.last_flush) >= FLUSH_SEC):
            self.flush(force=True)
        if (now - self.last_hb) >= HB_SEC:
            self.heartbeat()
            self.last_hb = now
        if (now - self.last_snap) >= SNAP_SEC:
            self.snapshot()
            self.last_snap = now
        if (now - self.last_guard) >= 300:
            self.guard_space()
            self.last_guard = now
        self.rotate()

    # ------------------------------------------------------------------ 入口
    def boots_record(self):
        p = os.path.join(LOG_DIR, "boots.tsv")
        fresh = not os.path.exists(p)
        try:
            with open(p, "a") as fh:
                if fresh:
                    fh.write("# boot_id\trelease\tfirst_seen\tuptime_at_start\n")
                fh.write("%s\t%s\t%s\t%.1f\n" % (self.bid, os.uname().release, now_iso(), uptime_sec()))
                fh.flush()
                os.fdatasync(fh.fileno())
        except Exception:
            pass

    def run(self):
        os.makedirs(LOG_DIR, exist_ok=True)
        self.boots_record()
        self.open_log()
        self.open_snapshot()
        self.write(("[z17s-logwatch] start pid=%d boot_id=%s kernel=%s host=%s\n"
                    % (os.getpid(), self.bid, os.uname().release, os.uname().nodename)).encode())
        # 脚本启动前 ring buffer 里已有的内容（也就是本次开机日志）先整体落下来
        try:
            dump = subprocess.run(["dmesg", "--time-format=iso"],
                                  capture_output=True, timeout=30).stdout
            self.write(b"[z17s-logwatch] --- initial dmesg dump ---\n" + dump)
            if not dump.endswith(b"\n"):
                self.write(b"\n")
            self.write(b"[z17s-logwatch] --- live follow starts ---\n")
        except Exception as e:
            self.write(("[z17s-logwatch] initial dmesg dump failed: %s\n" % e).encode())
        self.flush(force=True)

        try:
            kfd = os.open(KMSG, os.O_RDONLY | os.O_NONBLOCK)
        except Exception as e:
            sys.stderr.write("z17s-logwatch: cannot open %s: %s\n" % (KMSG, e))
            return 2

        sys.stderr.write("z17s-logwatch: following %s -> %s\n" % (KMSG, self.path))
        sys.stderr.flush()

        # 首次心跳/快照立刻做一次；同时把时间基准设为"现在"，
        # 否则 tick() 里的 (now - 0.0) >= HB_SEC 会立刻再打一次，启动瞬间出现重复行
        now = time.monotonic()
        self.last_hb = now
        self.last_snap = now
        self.heartbeat()
        self.snapshot()

        while _running:
            self.pump(kfd)
            self.tick()
            time.sleep(POLL_SEC)

        self.write(b"[z17s-logwatch] stopping (signal)\n")
        self.flush(force=True)
        if self.ser_fd is not None:
            try:
                os.close(self.ser_fd)
            except OSError:
                pass
            self.ser_fd = None
        for fh in (self.fh, self.snap_fh):
            try:
                if fh:
                    fh.close()
            except Exception:
                pass
        return 0


def main():
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    return LogWatch().run()


if __name__ == "__main__":
    sys.exit(main())
