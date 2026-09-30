#!/usr/bin/env python3
# Force a kernel-level restart, bypassing systemd entirely.
#   syscall(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
#           LINUX_REBOOT_CMD_RESTART, NULL)
# arm64 generic syscall table: reboot = 142
import ctypes, sys

libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.syscall.restype = ctypes.c_long
libc.syscall.argtypes = [ctypes.c_long, ctypes.c_ulong, ctypes.c_ulong,
                         ctypes.c_ulong, ctypes.c_ulong]

MAGIC1 = 0xfee1dead
MAGIC2 = 672274793            # LINUX_REBOOT_MAGIC2
CMD_RESTART = 0x01234567      # LINUX_REBOOT_CMD_RESTART

print("calling reboot(2) ...", flush=True)
sys.stdout.flush()
r = libc.syscall(142, MAGIC1, MAGIC2, CMD_RESTART, 0)
# if we get here the syscall failed
print("reboot syscall returned %d errno=%d (%s)"
      % (r, ctypes.get_errno(), __import__("os").strerror(ctypes.get_errno())),
      flush=True)
