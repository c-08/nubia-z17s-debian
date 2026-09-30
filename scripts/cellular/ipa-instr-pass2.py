#!/usr/bin/env python3
# ============================================================================
# Z17S IPA instrumentation pass 2  (TX / completion path)
#
# Pass 1 (ipa_instr.py) answered S1: the freeze is in
#   ipa_power_disable() -> icc_bulk_disable().
#
# Pass 2 answers G4: why does rmnet_ipa0 TX stop after ~2 packets?
#   hypotheses: (a) gsi_channel_trans_alloc() -> tre_reserve exhausted
#               (b) pm_runtime_get() < 1  -> NETDEV_TX_BUSY, queue left stopped
#               (c) GSI TX never completes (no IEOB)
#
# Traces added (tag Z17SIPA2, no mdelay so a failure storm can't look hung):
#   gsi_trans.c  gsi_trans_tre_reserve()  failure + available count
#   gsi_trans.c  gsi_channel_trans_alloc() -> NULL
#   gsi.c        gsi_isr_ieob()           every completion interrupt
#   ipa_endpoint.c ipa_endpoint_skb_tx()  trans == NULL
#   ipa_modem.c  ipa_start_xmit()         pm_runtime_get()<1, skb_tx!=0
#   ipa_modem.c  ipa_modem_wake_queue_work() / netif_wake_queue
# ============================================================================
import os, re, sys

SRC = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa"

MACRO = """
#ifndef IPATR2
/* ---- Z17S temporary instrumentation (remove before commit) ---- */
#define IPATR2(fmt, ...) \\
	pr_info("Z17SIPA2 %s:%d " fmt "\\n", __func__, __LINE__, ##__VA_ARGS__)
#endif
"""

# ---------------------------------------------------------------- helpers
def load(fn):
    p = os.path.join(SRC, fn)
    with open(p) as f:
        return p, f.read()

def sub1(text, old, new, tag):
    n = text.count(old)
    if n != 1:
        print("  !! %-42s matched %d times (expected 1)" % (tag, n), flush=True)
        return text, False
    print("  ok %-42s" % tag, flush=True)
    return text.replace(old, new), True

def backup(p):
    if not os.path.exists(p + ".orig2"):
        import shutil
        shutil.copy2(p, p + ".orig2")

# ---------------------------------------------------------------- gsi_trans.c
p, t = load("gsi_trans.c")
backup(p)
ok = []
t, r = sub1(t, '#include "ipa_gsi.h"\n',
            '#include "ipa_gsi.h"\n' + MACRO, "gsi_trans: macro")
ok.append(r)

t, r = sub1(t,
"""		new = avail - (int)tre_count;
		if (unlikely(new < 0))
			return false;
""",
"""		new = avail - (int)tre_count;
		if (unlikely(new < 0)) {
			IPATR2("tre_reserve FAIL need=%u avail=%d",
			       tre_count, atomic_read(&trans_info->tre_avail));
			return false;
		}
""", "gsi_trans: tre_reserve fail")
ok.append(r)

t, r = sub1(t,
"""	if (!gsi_trans_tre_reserve(trans_info, tre_count))
		return NULL;
""",
"""	if (!gsi_trans_tre_reserve(trans_info, tre_count)) {
		IPATR2("trans_alloc NULL ch=%u tre=%u", channel_id, tre_count);
		return NULL;
	}
""", "gsi_trans: trans_alloc NULL")
ok.append(r)

if all(ok):
    with open(p, "w") as f:
        f.write(t)
else:
    print("  gsi_trans.c NOT written (a match failed)")

# ---------------------------------------------------------------- gsi.c
p, t = load("gsi.c")
backup(p)
ok = []
t, r = sub1(t,
"""	gsi_irq_ieob_disable(gsi, event_mask);
""",
"""	IPATR2("isr_ieob mask=0x%x", event_mask);
	gsi_irq_ieob_disable(gsi, event_mask);
""", "gsi: isr_ieob")
ok.append(r)
if all(ok):
    with open(p, "w") as f:
        f.write(t)
else:
    print("  gsi.c NOT written")

# ---------------------------------------------------------------- ipa_endpoint.c
p, t = load("ipa_endpoint.c")
backup(p)
if "IPATR2" not in t:
    t = t.replace('#define IPATR(fmt, ...) do { \\\n',
                  '#define IPATR2(fmt, ...) \\\n\tpr_info("Z17SIPA2 %s:%d " fmt "\\n", __func__, __LINE__, ##__VA_ARGS__)\n\n'
                  '#define IPATR(fmt, ...) do { \\\n', 1)
ok = []
t, r = sub1(t,
"""	trans = ipa_endpoint_trans_alloc(endpoint, 1 + nr_frags);
	if (!trans)
		return -EBUSY;
""",
"""	trans = ipa_endpoint_trans_alloc(endpoint, 1 + nr_frags);
	if (!trans) {
		IPATR2("skb_tx trans=NULL ep=%u ch=%u nr_frags=%u",
		       endpoint->endpoint_id, endpoint->channel_id, nr_frags);
		return -EBUSY;
	}
""", "ipa_endpoint: skb_tx NULL")
ok.append(r)
if all(ok):
    with open(p, "w") as f:
        f.write(t)
else:
    print("  ipa_endpoint.c NOT written")

# ---------------------------------------------------------------- ipa_modem.c
p, t = load("ipa_modem.c")
backup(p)
if "IPATR2" not in t:
    t = t.replace('#define IPATR(fmt, ...) do { \\\n',
                  '#define IPATR2(fmt, ...) \\\n\tpr_info("Z17SIPA2 %s:%d " fmt "\\n", __func__, __LINE__, ##__VA_ARGS__)\n\n'
                  '#define IPATR(fmt, ...) do { \\\n', 1)
ok = []
t, r = sub1(t,
"""	dev = ipa->dev;
	ret = pm_runtime_get(dev);
""",
"""	dev = ipa->dev;
	ret = pm_runtime_get(dev);
	if (ret < 1)
		IPATR2("xmit pm_get ret=%d proto=0x%04x", ret,
		       ntohs(skb->protocol));
""", "ipa_modem: pm_get")
ok.append(r)

t, r = sub1(t,
"""	ret = ipa_endpoint_skb_tx(endpoint, skb);
""",
"""	ret = ipa_endpoint_skb_tx(endpoint, skb);
	if (ret)
		IPATR2("xmit skb_tx ret=%d len=%u", ret, skb_len);
""", "ipa_modem: skb_tx ret")
ok.append(r)

t, r = sub1(t,
"""	netif_wake_queue(priv->tx->netdev);
""",
"""	IPATR2("wake_queue_work: waking TX queue");
	netif_wake_queue(priv->tx->netdev);
""", "ipa_modem: wake_queue_work")
ok.append(r)
if all(ok):
    with open(p, "w") as f:
        f.write(t)
else:
    print("  ipa_modem.c NOT written")

print("\n=== instrumentation pass 2 applied ===")
