#!/usr/bin/env python3
# ============================================================================
# Z17S IPA instrumentation pass 3 -- the sequencer experiment
#
# Ground truth from pass 2 (clean boot, no rmmod/down):
#   * ipa_endpoint_skb_tx() never failed  (xmit skb_tx = 0, skb_tx trans=NULL = 0)
#   * pm_runtime_get() never returned < 1 (xmit pm_get = 0)
#   * rmnet_ipa0 TX = 2 packets OK ... and isr_ieob never moved during the ping
#   => TREs ARE committed on ch5, but the IPA NEVER completes them.
#
# ipa_endpoint.c writes ENDP_INIT_SEQ as:
#   SEQ_TYPE     = endpoint->config.tx.seq_type        (always)
#   SEQ_REP_TYPE = endpoint->config.tx.seq_rep_type    (only if version < 4.5)
# Our v3.1 table has seq_rep_type = 0, while sdm845's working QMAP TX uses
# IPA_SEQ_REP_DMA_PARSER (0x08).  A 2-pass sequencer with no replication
# sequencer would stall exactly like this.
#
# So: make seq_type / seq_rep_type overridable at RUNTIME via module params,
# re-written per packet, so several configs can be swept in ONE boot.
#
# Extra:
#   * gsi_channel_trans_quiesce() -> bounded (3s) so `down`/`rmmod` no longer
#     wedge the whole machine (it waits for the never-completing transaction).
#   * traces on the xmit entry (queue state), trans_commit and trans_complete.
#
# usage on device:
#   insmod ipa-instr3.ko
#   echo 12 > /sys/module/ipa/parameters/z17s_seq     # 0x0c 3_PASS_SKIP_LAST_UC
#   echo 8  > /sys/module/ipa/parameters/z17s_rep     # 0x08 REP_DMA_PARSER
#   ... ping ...
# ============================================================================
import os, shutil

SRC = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa"

def load(fn):
    p = os.path.join(SRC, fn)
    return p, open(p).read()

def save(p, t):
    if not os.path.exists(p + ".orig3"):
        shutil.copy2(p, p + ".orig3")
    open(p, "w").write(t)

def sub1(text, old, new, tag):
    n = text.count(old)
    if n != 1:
        print("  !! %-44s matched %d (expected 1)" % (tag, n), flush=True)
        return text, False
    print("  ok %-44s" % tag, flush=True)
    return text.replace(old, new, 1), True

ok_all = True

# ============================================================ gsi.c
# bounded quiesce + trace
p, t = load("gsi.c")
t, r = sub1(t,
"""	trans = gsi_channel_trans_last(channel);
	if (trans) {
		wait_for_completion(&trans->completion);
		gsi_trans_free(trans);
	}
""",
"""	trans = gsi_channel_trans_last(channel);
	if (trans) {
		unsigned long left;

		left = wait_for_completion_timeout(&trans->completion, 3 * HZ);
		if (!left)
			IPATR2("quiesce TIMEOUT ch=%u (bounded 3s)",
			       gsi_channel_id(channel));
		gsi_trans_free(trans);
	}
""", "gsi: quiesce bounded")
ok_all &= r
if r:
    save(p, t)

# ============================================================ ipa_endpoint.c
p, t = load("ipa_endpoint.c")
if "#include <linux/module.h>" not in t:
    t2, r = sub1(t, '#define IPATR2(fmt, ...) \\\n',
                 '#include <linux/module.h>\n#define IPATR2(fmt, ...) \\\n',
                 "ipa_endpoint: +module.h")
    t = t2 if r else t
    ok_all &= r

PARAMS = """
/* ---- Z17S experiment: runtime-overridable AP_MODEM_TX sequencer ---- */
static int z17s_seq = -1;
module_param(z17s_seq, int, 0644);
static int z17s_rep = -1;
module_param(z17s_rep, int, 0644);

/* Re-write ENDP_INIT_SEQ for one endpoint using the override (if any) */
static void z17s_apply_seq(struct ipa_endpoint *endpoint)
{
	struct ipa *ipa = endpoint->ipa;
	const struct reg *reg;
	u32 seq;
	u32 rep;
	u32 val;

	if (z17s_seq < 0 && z17s_rep < 0)
		return;

	seq = z17s_seq < 0 ? (u32)endpoint->config.tx.seq_type : (u32)z17s_seq;
	rep = z17s_rep < 0 ? (u32)endpoint->config.tx.seq_rep_type : (u32)z17s_rep;

	reg = ipa_reg(ipa, ENDP_INIT_SEQ);
	val = reg_encode(reg, SEQ_TYPE, seq);
	if (ipa->version < IPA_VERSION_4_5)
		val |= reg_encode(reg, SEQ_REP_TYPE, rep);

	iowrite32(val, ipa->reg_virt + reg_n_offset(reg, endpoint->endpoint_id));
	IPATR2("SEQ override ep=%u seq=0x%x rep=0x%x -> 0x%08x",
	       endpoint->endpoint_id, seq, rep, val);
}
"""

anchor = "#endif\n\n#define IPATR(fmt, ...) do { \\\n"
if "z17s_apply_seq" not in t:
    t2, r = sub1(t, anchor, "#endif\n" + PARAMS + "\n#define IPATR(fmt, ...) do { \\\n",
                 "ipa_endpoint: seq override")
    t = t2 if r else t
    ok_all &= r

t, r = sub1(t,
"""	trans = ipa_endpoint_trans_alloc(endpoint, 1 + nr_frags);
""",
"""	if (endpoint->endpoint_id == 3)		/* AP_MODEM_TX */
		z17s_apply_seq(endpoint);

	trans = ipa_endpoint_trans_alloc(endpoint, 1 + nr_frags);
""", "ipa_endpoint: apply hook")
ok_all &= r
if r:
    save(p, t)

# ============================================================ ipa_modem.c
p, t = load("ipa_modem.c")
if "z17s_xmit_n" not in t:
    t2, r = sub1(t, '#define IPATR(fmt, ...) do { \\\n',
                 'static int z17s_xmit_n;\n\n#define IPATR(fmt, ...) do { \\\n',
                 "ipa_modem: counter")
    t = t2 if r else t
    ok_all &= r

t, r = sub1(t,
"""	if (!skb_len)
		goto err_drop_skb;
""",
"""	if (z17s_xmit_n < 40) {
		z17s_xmit_n++;
		IPATR2("xmit IN len=%u proto=0x%04x stop=%d",
		       skb_len, ntohs(skb->protocol),
		       netif_xmit_stopped(netdev_get_tx_queue(netdev, 0)));
	}

	if (!skb_len)
		goto err_drop_skb;
""", "ipa_modem: xmit entry")
ok_all &= r
if r:
    save(p, t)

# ============================================================ gsi_trans.c
p, t = load("gsi_trans.c")
if "z17s_commit_n" not in t:
    t2, r = sub1(t, '#define IPATR2(fmt, ...) \\\n',
                 'static int z17s_commit_n;\nstatic int z17s_complete_n;\n\n#define IPATR2(fmt, ...) \\\n',
                 "gsi_trans: counters")
    t = t2 if r else t
    ok_all &= r

t, r = sub1(t,
"""void gsi_trans_commit(struct gsi_trans *trans, bool ring_db)
{
	if (trans->used_count)
""",
"""void gsi_trans_commit(struct gsi_trans *trans, bool ring_db)
{
	if (z17s_commit_n < 40) {
		z17s_commit_n++;
		IPATR2("trans_commit ch=%u used=%u ring_db=%d",
		       trans->channel_id, trans->used_count, ring_db);
	}
	if (trans->used_count)
""", "gsi_trans: commit trace")
ok_all &= r

t, r = sub1(t,
"""void gsi_trans_complete(struct gsi_trans *trans)
{
""",
"""void gsi_trans_complete(struct gsi_trans *trans)
{
	if (z17s_complete_n < 40) {
		z17s_complete_n++;
		IPATR2("trans_COMPLETE ch=%u", trans->channel_id);
	}
""", "gsi_trans: complete trace")
ok_all &= r
if r:
    save(p, t)

print("\n=== pass 3 applied (all_ok=%s) ===" % ok_all)
