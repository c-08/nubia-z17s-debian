#!/usr/bin/env python3
# Patch ipa_main.c: forbid runtime suspend so ipa_power_disable() (which
# freezes the whole machine on msm8998 via icc_bulk_disable) is never reached.
#
# The platform interconnect cannot be disabled (sync bus stall -> watchdog).
# Runtime suspend is the only path into ipa_power_disable, so forbidding it
# keeps IPA permanently active.
import shutil

p = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa/ipa_main.c"
shutil.copy2(p, p + ".orig-nosusp")

t = open(p).read()

old = """done:
	pm_runtime_mark_last_busy(dev);
	(void)pm_runtime_put_autosuspend(dev);
"""
new = """done:
	/*
	 * Z17S (msm8998): the platform interconnect MUST NOT be powered down
	 * (icc_bulk_disable() stalls the sync bus -> zero kernel output ->
	 * watchdog reset ~35s).  Runtime suspend is the only path into
	 * ipa_power_disable(), so forbid it to keep IPA permanently active.
	 * This matters most in MODEM loader mode, where probe returns here
	 * right after ipa_config() and would otherwise autosuspend
	 * immediately (before the modem's setup-ready interrupt arrives).
	 */
	pm_runtime_mark_last_busy(dev);
	pm_runtime_forbid(dev);
"""

assert t.count(old) == 1, "anchor count=%d" % t.count(old)
open(p, "w").write(t.replace(old, new, 1))
print("ipa_main.c patched: pm_runtime_forbid instead of autosuspend")
