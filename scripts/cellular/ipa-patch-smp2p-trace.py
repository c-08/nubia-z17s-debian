#!/usr/bin/env python3
# 给 ipa_smp2p_notify() 和 notify_reset() 加 Z17SMP2P trace，打印 power_on 值与 runtime 状态
import sys

p = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa/ipa_smp2p.c"
t = open(p).read()

# 1) notify() 里 power_on 赋值后加 trace
old1 = """	smp2p->power_on = pm_runtime_get_if_active(smp2p->ipa->dev) > 0;

	/* Signal whether the IPA power is enabled */
"""
new1 = """	smp2p->power_on = pm_runtime_get_if_active(smp2p->ipa->dev) > 0;
	pr_info("Z17SMP2P notify: power_on=%d status=%d usage=%d notified=%d\\n",
		smp2p->power_on,
		atomic_read(&smp2p->ipa->dev->power.usage_count) != 0,
		0,
		smp2p->notified);

	/* Signal whether the IPA power is enabled */
"""
assert t.count(old1) == 1, "old1 count=%d" % t.count(old1)
t = t.replace(old1, new1, 1)

# 2) notify 的 notified 提前 return 处加 trace
old2 = """	if (smp2p->notified)
		return;
"""
new2 = """	if (smp2p->notified) {
		pr_info("Z17SMP2P notify: SKIP already-notified\\n");
		return;
	}
"""
assert t.count(old2) == 1, "old2 count=%d" % t.count(old2)
t = t.replace(old2, new2, 1)

# 3) notify_reset 里加 trace
old3 = """void ipa_smp2p_notify_reset(struct ipa *ipa)
{
	struct ipa_smp2p *smp2p = ipa->smp2p;
	u32 mask;

	if (!smp2p->notified)
		return;
"""
new3 = """void ipa_smp2p_notify_reset(struct ipa *ipa)
{
	struct ipa_smp2p *smp2p = ipa->smp2p;
	u32 mask;

	pr_info("Z17SMP2P notify_reset: enter notified=%d\\n", smp2p->notified);

	if (!smp2p->notified)
		return;
"""
assert t.count(old3) == 1, "old3 count=%d" % t.count(old3)
t = t.replace(old3, new3, 1)

open(p, "w").write(t)
print("OK: 3 trace points added to ipa_smp2p.c")
