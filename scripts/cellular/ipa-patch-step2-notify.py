#!/usr/bin/env python3
# Step 2: actively notify the modem of IPA power state after ipa_setup()
# completes (SELF loader mode).  Mirrors the downstream ipa3_uc_notify_clk_state(true)
# that runs when the uC finishes loading.  Without this, the msm8998 modem
# waits for the AP's clock-enabled signal and, not receiving it, does
# "APPS force stop" (sys_m_smsm_mpss.c:285).
import shutil

SRC = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa"

def load(fn):
    p = SRC + "/" + fn
    return p, open(p).read()

def backup(p):
    if not __import__("os").path.exists(p + ".orig-step2"):
        shutil.copy2(p, p + ".orig-step2")

def sub1(t, old, new, tag):
    n = t.count(old)
    if n != 1:
        print("  !! %-46s matched %d (expected 1)" % (tag, n))
        return t, False
    print("  ok %-46s" % tag)
    return t.replace(old, new, 1), True

ok = True

# ============================================================ ipa_smp2p.h
p, t = load("ipa_smp2p.h")
backup(p)
t, r = sub1(t,
"""/**
 * ipa_smp2p_notify_reset() - Reset modem notification state
 * @ipa:	IPA pointer
 *
 * Return:	0 if successful, or a negative error code
 */
void ipa_smp2p_notify_reset(struct ipa *ipa);
""",
"""/**
 * ipa_smp2p_notify_reset() - Reset modem notification state
 * @ipa:	IPA pointer
 *
 * Return:	0 if successful, or a negative error code
 */
void ipa_smp2p_notify_reset(struct ipa *ipa);

/**
 * ipa_smp2p_notify_power() - Actively tell the modem the IPA power state
 * @ipa:	IPA pointer
 *
 * Z17S (msm8998): the modem firmware waits for the AP to signal whether the
 * IPA clock is enabled before it finishes its own init.  In the downstream
 * driver this happens via ipa3_uc_notify_clk_state(true) once the uC is up;
 * the mainline driver only notified on a clock-query interrupt, which is too
 * late / never arrives in SELF loader mode.  Call this after ipa_setup().
 */
void ipa_smp2p_notify_power(struct ipa *ipa);
""", "smp2p.h: decl")
ok &= r
open(p, "w").write(t)

# ============================================================ ipa_smp2p.c
p, t = load("ipa_smp2p.c")
backup(p)
t, r = sub1(t,
"""void ipa_smp2p_notify_reset(struct ipa *ipa)
{
""",
"""/* Z17S Step 2: public wrapper so ipa_setup() can notify the modem that the
 * IPA power is on (and keep the reference), matching downstream
 * ipa3_uc_notify_clk_state(true).
 */
void ipa_smp2p_notify_power(struct ipa *ipa)
{
	if (!ipa->smp2p)
		return;

	ipa_smp2p_notify(ipa->smp2p);
}

void ipa_smp2p_notify_reset(struct ipa *ipa)
{
""", "smp2p.c: wrapper")
ok &= r
open(p, "w").write(t)

# ============================================================ ipa_main.c
p, t = load("ipa_main.c")
backup(p)
t, r = sub1(t,
"""	ipa->setup_complete = true;

	dev_info(dev, "IPA driver setup completed successfully\\n");
""",
"""	ipa->setup_complete = true;

	/* Z17S Step 2: tell the modem the IPA clock is on.  The msm8998 modem
	 * waits for this signal (downstream ipa3_uc_notify_clk_state(true));
	 * without it, it does "APPS force stop" after ~40s.
	 */
	ipa_smp2p_notify_power(ipa);

	dev_info(dev, "IPA driver setup completed successfully\\n");
""", "main.c: notify after setup")
ok &= r
open(p, "w").write(t)

print()
print("=== Step 2 applied (all_ok=%s) ===" % ok)
