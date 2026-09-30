#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Z17S: temporary instrumentation for the mainline qcom IPA driver.

Adds pr_info "Z17SIPA" traces (+300ms busy-wait) at every step of the
runtime-PM resume path and the netdev ndo_open path, so that a hard bus
hang leaves the last executed step in dmesg / logwatch / serial.

Locates functions by normalized signature line + first closing brace at
column 0 -> no manual line numbers.
"""
import io
import os
import shutil

BASE = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa"
MARK = "Z17SIPA"

MACRO = [
    "#include <linux/delay.h>",
    "",
    "/* ---- Z17S temporary IPA instrumentation (remove before commit) ---- */",
    "#define IPATR(fmt, ...) do { \\",
    '\tpr_info("Z17SIPA %s:%d " fmt "\\n", __func__, __LINE__, ##__VA_ARGS__); \\',
    "\tmdelay(300); \\",
    "} while (0)",
    "",
]


def norm(s):
    return "".join(s.split())


def find_sig(lines, sig, start=0):
    k = norm(sig)
    for i in range(start, len(lines)):
        if norm(lines[i]) == k:
            return i
    raise SystemExit("!! signature not found: %s" % sig)


def find_close(lines, start):
    # The closing brace of a top-level function is at column 0; an
    # indented "}" is a nested block and must NOT terminate the range.
    for i in range(start + 1, len(lines)):
        if lines[i] == "}":
            return i
    raise SystemExit("!! closing brace not found from line %d" % start)


def patch_file(fn, funcs):
    path = os.path.join(BASE, fn)
    src = io.open(path, encoding="utf-8").read()
    if MARK in src:
        print("== %s already instrumented, skip" % fn)
        return False
    lines = src.split("\n")
    jobs = []
    for sig, body in funcs:
        s = find_sig(lines, sig)
        e = find_close(lines, s)
        jobs.append((s, e, body))
    jobs.sort(key=lambda j: j[0], reverse=True)
    for s, e, body in jobs:
        lines[s:e + 1] = body
    for i, ln in enumerate(lines):
        if ln.startswith("#include"):
            lines[i:i] = MACRO
            break
    new = "\n".join(lines)
    shutil.copy2(path, path + ".orig")
    io.open(path, "w", encoding="utf-8").write(new)
    print("++ %s: %d funcs  %d -> %d bytes" % (fn, len(jobs), len(src), len(new)))
    return True


# =====================================================================
# ipa_power.c
# =====================================================================
IPA_POWER_FUNCS = [
    ("static int ipa_power_enable(struct ipa *ipa)", [
        "static int ipa_power_enable(struct ipa *ipa)",
        "{",
        "\tstruct ipa_power *power = ipa->power;",
        "\tint ret;",
        "",
        '\tIPATR("pwren: -> icc_bulk_enable(n=%u)", power->interconnect_count);',
        "\tret = icc_bulk_enable(power->interconnect_count, power->interconnect);",
        '\tIPATR("pwren: <- icc_bulk_enable ret=%d", ret);',
        "\tif (ret)",
        "\t\treturn ret;",
        "",
        '\tIPATR("pwren: -> clk_prepare_enable(core)");',
        "\tret = clk_prepare_enable(power->core);",
        '\tIPATR("pwren: <- clk_prepare_enable ret=%d", ret);',
        "\tif (ret) {",
        '\t\tdev_err(power->dev, "error %d enabling core clock\\n", ret);',
        "\t\ticc_bulk_disable(power->interconnect_count,",
        "\t\t\t\t power->interconnect);",
        "\t}",
        "",
        "\treturn ret;",
        "}",
    ]),
    ("static void ipa_power_disable(struct ipa *ipa)", [
        "static void ipa_power_disable(struct ipa *ipa)",
        "{",
        "\tstruct ipa_power *power = ipa->power;",
        "",
        '\tIPATR("pwroff: -> clk_disable_unprepare(core)");',
        "\tclk_disable_unprepare(power->core);",
        '\tIPATR("pwroff: <- clk_disable_unprepare");',
        '\tIPATR("pwroff: -> icc_bulk_disable(n=%u)", power->interconnect_count);',
        "\ticc_bulk_disable(power->interconnect_count, power->interconnect);",
        '\tIPATR("pwroff: <- icc_bulk_disable");',
        "}",
    ]),
    ("static int ipa_runtime_suspend(struct device *dev)", [
        "static int ipa_runtime_suspend(struct device *dev)",
        "{",
        "\tstruct ipa *ipa = dev_get_drvdata(dev);",
        "",
        '\tIPATR("rt_suspend: enter setup_complete=%d", ipa->setup_complete);',
        "\tif (ipa->setup_complete) {",
        '\t\tIPATR("rt_suspend: -> ipa_endpoint_suspend()");',
        "\t\tipa_endpoint_suspend(ipa);",
        '\t\tIPATR("rt_suspend: <- ipa_endpoint_suspend()");',
        '\t\tIPATR("rt_suspend: -> gsi_suspend()");',
        "\t\tgsi_suspend(&ipa->gsi);",
        '\t\tIPATR("rt_suspend: <- gsi_suspend()");',
        "\t}",
        "",
        '\tIPATR("rt_suspend: -> ipa_power_disable()");',
        "\tipa_power_disable(ipa);",
        '\tIPATR("rt_suspend: <- ipa_power_disable() exit");',
        "",
        "\treturn 0;",
        "}",
    ]),
    ("static int ipa_runtime_resume(struct device *dev)", [
        "static int ipa_runtime_resume(struct device *dev)",
        "{",
        "\tstruct ipa *ipa = dev_get_drvdata(dev);",
        "\tint ret;",
        "",
        '\tIPATR("rt_resume: enter setup_complete=%d", ipa->setup_complete);',
        '\tIPATR("rt_resume: -> ipa_power_enable()");',
        "\tret = ipa_power_enable(ipa);",
        '\tIPATR("rt_resume: <- ipa_power_enable ret=%d", ret);',
        "\tif (WARN_ON(ret < 0))",
        "\t\treturn ret;",
        "",
        "\tif (ipa->setup_complete) {",
        '\t\tIPATR("rt_resume: -> gsi_resume()");',
        "\t\tgsi_resume(&ipa->gsi);",
        '\t\tIPATR("rt_resume: <- gsi_resume()");',
        '\t\tIPATR("rt_resume: -> ipa_endpoint_resume()");',
        "\t\tipa_endpoint_resume(ipa);",
        '\t\tIPATR("rt_resume: <- ipa_endpoint_resume()");',
        "\t}",
        "",
        '\tIPATR("rt_resume: exit");',
        "",
        "\treturn 0;",
        "}",
    ]),
]


# =====================================================================
# ipa_endpoint.c
# =====================================================================
IPA_ENDPOINT_FUNCS = [
    ("int ipa_endpoint_enable_one(struct ipa_endpoint *endpoint)", [
        "int ipa_endpoint_enable_one(struct ipa_endpoint *endpoint)",
        "{",
        "\tu32 endpoint_id = endpoint->endpoint_id;",
        "\tstruct ipa *ipa = endpoint->ipa;",
        "\tstruct gsi *gsi = &ipa->gsi;",
        "\tint ret;",
        "",
        '\tIPATR("ep_enable: id=%u ch=%u toward=%d -> gsi_channel_start()",',
        "\t      endpoint_id, endpoint->channel_id,",
        "\t      (int)endpoint->toward_ipa);",
        "\tret = gsi_channel_start(gsi, endpoint->channel_id);",
        '\tIPATR("ep_enable: id=%u <- gsi_channel_start ret=%d",',
        "\t      endpoint_id, ret);",
        "\tif (ret) {",
        "\t\tdev_err(ipa->dev,",
        '\t\t\t"error %d starting %cX channel %u for endpoint %u\\n",',
        "\t\t\tret, endpoint->toward_ipa ? 'T' : 'R',",
        "\t\t\tendpoint->channel_id, endpoint_id);",
        "\t\treturn ret;",
        "\t}",
        "",
        "\tif (!endpoint->toward_ipa) {",
        '\t\tIPATR("ep_enable: id=%u -> ipa_interrupt_suspend_enable()",',
        "\t\t      endpoint_id);",
        "\t\tipa_interrupt_suspend_enable(ipa->interrupt, endpoint_id);",
        '\t\tIPATR("ep_enable: id=%u -> ipa_endpoint_replenish_enable()",',
        "\t\t      endpoint_id);",
        "\t\tipa_endpoint_replenish_enable(endpoint);",
        "\t}",
        "",
        "\t__set_bit(endpoint_id, ipa->enabled);",
        '\tIPATR("ep_enable: id=%u DONE ok", endpoint_id);',
        "",
        "\treturn 0;",
        "}",
    ]),
    ("void ipa_endpoint_disable_one(struct ipa_endpoint *endpoint)", [
        "void ipa_endpoint_disable_one(struct ipa_endpoint *endpoint)",
        "{",
        "\tu32 endpoint_id = endpoint->endpoint_id;",
        "\tstruct ipa *ipa = endpoint->ipa;",
        "\tstruct gsi *gsi = &ipa->gsi;",
        "\tint ret;",
        "",
        '\tIPATR("ep_disable: id=%u enabled=%d", endpoint_id,',
        "\t      (int)test_bit(endpoint_id, ipa->enabled));",
        "",
        "\tif (!test_bit(endpoint_id, ipa->enabled))",
        "\t\treturn;",
        "",
        "\t__clear_bit(endpoint_id, endpoint->ipa->enabled);",
        "",
        "\tif (!endpoint->toward_ipa) {",
        "\t\tipa_endpoint_replenish_disable(endpoint);",
        "\t\tipa_interrupt_suspend_disable(ipa->interrupt, endpoint_id);",
        "\t}",
        "",
        "\t/* Note that if stop fails, the channel's state is not well-defined */",
        '\tIPATR("ep_disable: id=%u -> gsi_channel_stop()", endpoint_id);',
        "\tret = gsi_channel_stop(gsi, endpoint->channel_id);",
        '\tIPATR("ep_disable: id=%u <- gsi_channel_stop ret=%d",',
        "\t      endpoint_id, ret);",
        "\tif (ret)",
        '\t\tdev_err(ipa->dev, "error %d attempting to stop endpoint %u\\n",',
        "\t\t\tret, endpoint_id);",
        "}",
    ]),
    ("void ipa_endpoint_suspend_one(struct ipa_endpoint *endpoint)", [
        "void ipa_endpoint_suspend_one(struct ipa_endpoint *endpoint)",
        "{",
        "\tstruct device *dev = endpoint->ipa->dev;",
        "\tstruct gsi *gsi = &endpoint->ipa->gsi;",
        "\tint ret;",
        "",
        '\tIPATR("ep_suspend_one: id=%u toward=%d enabled=%d",',
        "\t      endpoint->endpoint_id, (int)endpoint->toward_ipa,",
        "\t      (int)test_bit(endpoint->endpoint_id,",
        "\t\t\t     endpoint->ipa->enabled));",
        "",
        "\tif (!test_bit(endpoint->endpoint_id, endpoint->ipa->enabled))",
        "\t\treturn;",
        "",
        "\tif (!endpoint->toward_ipa) {",
        '\t\tIPATR("ep_suspend_one: id=%u -> replenish_disable",',
        "\t\t      endpoint->endpoint_id);",
        "\t\tipa_endpoint_replenish_disable(endpoint);",
        '\t\tIPATR("ep_suspend_one: id=%u -> program_suspend(true)",',
        "\t\t      endpoint->endpoint_id);",
        "\t\t(void)ipa_endpoint_program_suspend(endpoint, true);",
        "\t}",
        "",
        '\tIPATR("ep_suspend_one: id=%u -> gsi_channel_suspend(ch=%u)",',
        "\t      endpoint->endpoint_id, endpoint->channel_id);",
        "\tret = gsi_channel_suspend(gsi, endpoint->channel_id);",
        '\tIPATR("ep_suspend_one: id=%u <- gsi_channel_suspend ret=%d",',
        "\t      endpoint->endpoint_id, ret);",
        "\tif (ret)",
        '\t\tdev_err(dev, "error %d suspending channel %u\\n", ret,',
        "\t\t\tendpoint->channel_id);",
        "}",
    ]),
    ("void ipa_endpoint_resume_one(struct ipa_endpoint *endpoint)", [
        "void ipa_endpoint_resume_one(struct ipa_endpoint *endpoint)",
        "{",
        "\tstruct device *dev = endpoint->ipa->dev;",
        "\tstruct gsi *gsi = &endpoint->ipa->gsi;",
        "\tint ret;",
        "",
        '\tIPATR("ep_resume_one: id=%u toward=%d enabled=%d ch=%u",',
        "\t      endpoint->endpoint_id, (int)endpoint->toward_ipa,",
        "\t      (int)test_bit(endpoint->endpoint_id,",
        "\t\t\t     endpoint->ipa->enabled),",
        "\t      endpoint->channel_id);",
        "",
        "\tif (!test_bit(endpoint->endpoint_id, endpoint->ipa->enabled))",
        "\t\treturn;",
        "",
        "\tif (!endpoint->toward_ipa) {",
        '\t\tIPATR("ep_resume_one: id=%u -> program_suspend(false)",',
        "\t\t      endpoint->endpoint_id);",
        "\t\t(void)ipa_endpoint_program_suspend(endpoint, false);",
        "\t}",
        "",
        '\tIPATR("ep_resume_one: id=%u -> gsi_channel_resume(ch=%u)",',
        "\t      endpoint->endpoint_id, endpoint->channel_id);",
        "\tret = gsi_channel_resume(gsi, endpoint->channel_id);",
        '\tIPATR("ep_resume_one: id=%u <- gsi_channel_resume ret=%d",',
        "\t      endpoint->endpoint_id, ret);",
        "\tif (ret)",
        '\t\tdev_err(dev, "error %d resuming channel %u\\n", ret,',
        "\t\t\tendpoint->channel_id);",
        "\telse if (!endpoint->toward_ipa) {",
        '\t\tIPATR("ep_resume_one: id=%u -> replenish_enable",',
        "\t\t      endpoint->endpoint_id);",
        "\t\tipa_endpoint_replenish_enable(endpoint);",
        "\t}",
        "}",
    ]),
    ("void ipa_endpoint_suspend(struct ipa *ipa)", [
        "void ipa_endpoint_suspend(struct ipa *ipa)",
        "{",
        '\tIPATR("ep_suspend: enter setup_complete=%d", ipa->setup_complete);',
        "",
        "\tif (!ipa->setup_complete)",
        "\t\treturn;",
        "",
        "\tif (ipa->modem_netdev) {",
        '\t\tIPATR("ep_suspend: -> ipa_modem_suspend()");',
        "\t\tipa_modem_suspend(ipa->modem_netdev);",
        "\t}",
        "",
        '\tIPATR("ep_suspend: -> suspend_one(AP_LAN_RX)");',
        "\tipa_endpoint_suspend_one(ipa->name_map[IPA_ENDPOINT_AP_LAN_RX]);",
        '\tIPATR("ep_suspend: -> suspend_one(AP_COMMAND_TX)");',
        "\tipa_endpoint_suspend_one(ipa->name_map[IPA_ENDPOINT_AP_COMMAND_TX]);",
        '\tIPATR("ep_suspend: exit");',
        "}",
    ]),
    ("void ipa_endpoint_resume(struct ipa *ipa)", [
        "void ipa_endpoint_resume(struct ipa *ipa)",
        "{",
        '\tIPATR("ep_resume: enter setup_complete=%d modem_netdev=%d",',
        "\t      ipa->setup_complete, ipa->modem_netdev ? 1 : 0);",
        "",
        "\tif (!ipa->setup_complete)",
        "\t\treturn;",
        "",
        '\tIPATR("ep_resume: -> resume_one(AP_COMMAND_TX)");',
        "\tipa_endpoint_resume_one(ipa->name_map[IPA_ENDPOINT_AP_COMMAND_TX]);",
        '\tIPATR("ep_resume: -> resume_one(AP_LAN_RX)");',
        "\tipa_endpoint_resume_one(ipa->name_map[IPA_ENDPOINT_AP_LAN_RX]);",
        "",
        "\tif (ipa->modem_netdev) {",
        '\t\tIPATR("ep_resume: -> ipa_modem_resume()");',
        "\t\tipa_modem_resume(ipa->modem_netdev);",
        '\t\tIPATR("ep_resume: <- ipa_modem_resume()");',
        "\t}",
        '\tIPATR("ep_resume: exit");',
        "}",
    ]),
    ("ipa_endpoint_program_suspend(struct ipa_endpoint *endpoint, bool enable)", [
        "ipa_endpoint_program_suspend(struct ipa_endpoint *endpoint, bool enable)",
        "{",
        "\tbool suspended;",
        "",
        '\tIPATR("program_suspend: id=%u enable=%d ver=%d",',
        "\t      endpoint->endpoint_id, (int)enable,",
        "\t      (int)endpoint->ipa->version);",
        "",
        "\tif (endpoint->ipa->version >= IPA_VERSION_4_0)",
        "\t\treturn enable;\t/* For IPA v4.0+, no change made */",
        "",
        "\tWARN_ON(endpoint->toward_ipa);",
        "",
        "\tsuspended = ipa_endpoint_init_ctrl(endpoint, enable);",
        '\tIPATR("program_suspend: id=%u <- init_ctrl suspended=%d",',
        "\t      endpoint->endpoint_id, (int)suspended);",
        "",
        "\t/* A client suspended with an open aggregation frame will not",
        "\t * generate a SUSPEND IPA interrupt.  If enabling suspend, have",
        "\t * ipa_endpoint_suspend_aggr() handle this.",
        "\t */",
        "\tif (enable && !suspended)",
        "\t\tipa_endpoint_suspend_aggr(endpoint);",
        "",
        "\treturn suspended;",
        "}",
    ]),
]


# =====================================================================
# ipa_modem.c
# =====================================================================
IPA_MODEM_FUNCS = [
    ("static int ipa_open(struct net_device *netdev)", [
        "static int ipa_open(struct net_device *netdev)",
        "{",
        "\tstruct ipa_priv *priv = netdev_priv(netdev);",
        "\tstruct ipa *ipa = priv->ipa;",
        "\tstruct device *dev;",
        "\tint ret;",
        "",
        "\tdev = ipa->dev;",
        '\tIPATR("ipa_open: enter tx_ep=%u tx_ch=%u rx_ep=%u rx_ch=%u",',
        "\t      priv->tx->endpoint_id, priv->tx->channel_id,",
        "\t      priv->rx->endpoint_id, priv->rx->channel_id);",
        '\tIPATR("ipa_open: -> pm_runtime_get_sync()");',
        "\tret = pm_runtime_get_sync(dev);",
        '\tIPATR("ipa_open: <- pm_runtime_get_sync ret=%d", ret);',
        "\tif (ret < 0)",
        "\t\tgoto err_power_put;",
        "",
        '\tIPATR("ipa_open: -> ipa_endpoint_enable_one(TX)");',
        "\tret = ipa_endpoint_enable_one(priv->tx);",
        '\tIPATR("ipa_open: <- ipa_endpoint_enable_one(TX) ret=%d", ret);',
        "\tif (ret)",
        "\t\tgoto err_power_put;",
        "",
        '\tIPATR("ipa_open: -> ipa_endpoint_enable_one(RX)");',
        "\tret = ipa_endpoint_enable_one(priv->rx);",
        '\tIPATR("ipa_open: <- ipa_endpoint_enable_one(RX) ret=%d", ret);',
        "\tif (ret)",
        "\t\tgoto err_disable_tx;",
        "",
        '\tIPATR("ipa_open: -> netif_start_queue()");',
        "\tnetif_start_queue(netdev);",
        "",
        "\tpm_runtime_mark_last_busy(dev);",
        "\t(void)pm_runtime_put_autosuspend(dev);",
        '\tIPATR("ipa_open: exit OK");',
        "",
        "\treturn 0;",
        "",
        "err_disable_tx:",
        "\tipa_endpoint_disable_one(priv->tx);",
        "err_power_put:",
        "\tpm_runtime_put_noidle(dev);",
        "",
        "\treturn ret;",
        "}",
    ]),
    ("static int ipa_stop(struct net_device *netdev)", [
        "static int ipa_stop(struct net_device *netdev)",
        "{",
        "\tstruct ipa_priv *priv = netdev_priv(netdev);",
        "\tstruct ipa *ipa = priv->ipa;",
        "\tstruct device *dev;",
        "\tint ret;",
        "",
        "\tdev = ipa->dev;",
        '\tIPATR("ipa_stop: enter");',
        '\tIPATR("ipa_stop: -> pm_runtime_get_sync()");',
        "\tret = pm_runtime_get_sync(dev);",
        '\tIPATR("ipa_stop: <- pm_runtime_get_sync ret=%d", ret);',
        "\tif (ret < 0)",
        "\t\tgoto out_power_put;",
        "",
        "\tnetif_stop_queue(netdev);",
        "",
        '\tIPATR("ipa_stop: -> disable_one(RX)");',
        "\tipa_endpoint_disable_one(priv->rx);",
        '\tIPATR("ipa_stop: -> disable_one(TX)");',
        "\tipa_endpoint_disable_one(priv->tx);",
        "out_power_put:",
        "\tpm_runtime_mark_last_busy(dev);",
        "\t(void)pm_runtime_put_autosuspend(dev);",
        '\tIPATR("ipa_stop: exit");',
        "",
        "\treturn 0;",
        "}",
    ]),
    ("void ipa_modem_resume(struct net_device *netdev)", [
        "void ipa_modem_resume(struct net_device *netdev)",
        "{",
        "\tstruct ipa_priv *priv;",
        "",
        '\tIPATR("modem_resume: enter flags=0x%x", netdev->flags);',
        "",
        "\tif (!(netdev->flags & IFF_UP))",
        "\t\treturn;",
        "",
        "\tpriv = netdev_priv(netdev);",
        '\tIPATR("modem_resume: -> resume_one(tx ep=%u)",',
        "\t      priv->tx->endpoint_id);",
        "\tipa_endpoint_resume_one(priv->tx);",
        '\tIPATR("modem_resume: -> resume_one(rx ep=%u)",',
        "\t      priv->rx->endpoint_id);",
        "\tipa_endpoint_resume_one(priv->rx);",
        "",
        "\t/* Arrange for the TX queue to be restarted */",
        '\tIPATR("modem_resume: -> queue_pm_work()");',
        "\t(void)queue_pm_work(&priv->work);",
        '\tIPATR("modem_resume: exit");',
        "}",
    ]),
]


# =====================================================================
# gsi.c
# =====================================================================
GSI_FUNCS = [
    ("int gsi_channel_start(struct gsi *gsi, u32 channel_id)", [
        "int gsi_channel_start(struct gsi *gsi, u32 channel_id)",
        "{",
        "\tstruct gsi_channel *channel = &gsi->channel[channel_id];",
        "\tint ret;",
        "",
        '\tIPATR("gsi_ch_start: ch=%u evt=%u", channel_id,',
        "\t      channel->evt_ring_id);",
        "",
        "\t/* Enable NAPI and the completion interrupt */",
        "\tnapi_enable(&channel->napi);",
        '\tIPATR("gsi_ch_start: ch=%u -> gsi_irq_ieob_enable_one()",',
        "\t      channel_id);",
        "\tgsi_irq_ieob_enable_one(gsi, channel->evt_ring_id);",
        '\tIPATR("gsi_ch_start: ch=%u <- gsi_irq_ieob_enable_one()",',
        "\t      channel_id);",
        "",
        '\tIPATR("gsi_ch_start: ch=%u -> __gsi_channel_start(suspend=false)",',
        "\t      channel_id);",
        "\tret = __gsi_channel_start(channel, false);",
        '\tIPATR("gsi_ch_start: ch=%u <- __gsi_channel_start ret=%d",',
        "\t      channel_id, ret);",
        "\tif (ret) {",
        "\t\tgsi_irq_ieob_disable_one(gsi, channel->evt_ring_id);",
        "\t\tnapi_disable(&channel->napi);",
        "\t}",
        "",
        "\treturn ret;",
        "}",
    ]),
    ("int gsi_channel_suspend(struct gsi *gsi, u32 channel_id)", [
        "int gsi_channel_suspend(struct gsi *gsi, u32 channel_id)",
        "{",
        "\tstruct gsi_channel *channel = &gsi->channel[channel_id];",
        "\tint ret;",
        "",
        '\tIPATR("gsi_ch_suspend: ch=%u -> __gsi_channel_stop(suspend=true)",',
        "\t      channel_id);",
        "\tret = __gsi_channel_stop(channel, true);",
        '\tIPATR("gsi_ch_suspend: ch=%u <- ret=%d", channel_id, ret);',
        "\tif (ret)",
        "\t\treturn ret;",
        "",
        "\t/* Ensure NAPI polling has finished. */",
        "\tnapi_synchronize(&channel->napi);",
        '\tIPATR("gsi_ch_suspend: ch=%u done", channel_id);',
        "",
        "\treturn 0;",
        "}",
    ]),
    ("int gsi_channel_resume(struct gsi *gsi, u32 channel_id)", [
        "int gsi_channel_resume(struct gsi *gsi, u32 channel_id)",
        "{",
        "\tstruct gsi_channel *channel = &gsi->channel[channel_id];",
        "\tint ret;",
        "",
        '\tIPATR("gsi_ch_resume: ch=%u -> __gsi_channel_start(suspend=true)",',
        "\t      channel_id);",
        "\tret = __gsi_channel_start(channel, true);",
        '\tIPATR("gsi_ch_resume: ch=%u <- ret=%d", channel_id, ret);',
        "",
        "\treturn ret;",
        "}",
    ]),
]


JOBS = [
    ("ipa_power.c", IPA_POWER_FUNCS),
    ("ipa_endpoint.c", IPA_ENDPOINT_FUNCS),
    ("ipa_modem.c", IPA_MODEM_FUNCS),
    ("gsi.c", GSI_FUNCS),
]


def main():
    n = 0
    for fn, funcs in JOBS:
        if patch_file(fn, funcs):
            n += 1
    print("\n=== %d file(s) patched ===" % n)
    for fn, _ in JOBS:
        p = os.path.join(BASE, fn)
        c = io.open(p, encoding="utf-8").read().count(MARK)
        print("   %-16s Z17SIPA occurrences: %d" % (fn, c))


if __name__ == "__main__":
    main()
