#!/usr/bin/env python3
# ============================================================================
# z17s G3 cellular data call  --  SINGLE-PROCESS libqmi client
#
#   QRTR bus -> node 0 -> QmiDevice
#     [2] DPM  allocate_client + open_port(hw: EMBEDDED iface=1 rx=16 tx=3)
#     [3] WDS  allocate_client + bind_mux_data_port(mux=0, EMBEDDED iface=1)
#     [4] WDS  start_network(apn, ipv4)
#     [5] WDS  get_current_settings  -> IP / GW / DNS
#     [6] hold the process open (CID must stay alive or modem tears the call)
#
# qmicli cannot do this: one action per process, and qmi-proxy loses the
# QRTR port.  Everything here shares ONE QmiDevice and ONE connection.
#
# usage: qmi_up.py [apn] [tx] [rx] [iface] [mux] [hold_sec]
# ============================================================================
import gi, sys, os, time, subprocess

gi.require_version('Qrtr', '1.0')
gi.require_version('Qmi', '1.0')
from gi.repository import Qrtr, Qmi, GLib

APN = sys.argv[1] if len(sys.argv) > 1 else "3gnet"
TX = int(sys.argv[2]) if len(sys.argv) > 2 else 3
RX = int(sys.argv[3]) if len(sys.argv) > 3 else 16
IFACE = int(sys.argv[4]) if len(sys.argv) > 4 else 1
MUX = int(sys.argv[5]) if len(sys.argv) > 5 else 0
HOLD = int(sys.argv[6]) if len(sys.argv) > 6 else 5
NODE_ID = 0

# ---------------------------------------------------------------------------
# Round 87: when is bind_mux_data_port supposed to happen?
#
# qmi68.py binds the mux BEFORE start_network (t=0.09s vs 0.10s).  In CAF the
# mux is bound to a data port that belongs to an *existing* call, so binding
# first may be ACKed and then dropped on the floor: the modem has no call to
# attach mux 0 to, its ipa_ul never gets a mux -> UL pipe mapping, and every
# uplink packet that IPA delivers on ep18 is discarded silently.
#
#   BIND_MODE=before   bind, then start_network   (qmi68.py behaviour)
#   BIND_MODE=after    start_network, then bind
#   BIND_MODE=none     never bind at all
# ---------------------------------------------------------------------------
BIND_MODE = os.environ.get("BIND_MODE", "before")

print("=== single-process QMI  apn=%s tx=%d rx=%d iface=%d mux=%d hold=%d "
      "bind=%s ===" % (APN, TX, RX, IFACE, MUX, HOLD, BIND_MODE), flush=True)

loop = GLib.MainLoop()
S = {}
RC = [9]
_t0 = time.time()


def L(msg):
    print("%7.2fs  %s" % (time.time() - _t0, msg), flush=True)


def done(code):
    RC[0] = code
    loop.quit()


def fail(tag, e=None):
    print("", flush=True)
    if e is not None:
        print("[FAIL] %s: %s" % (tag, e), flush=True)
    else:
        print("[FAIL] %s" % tag, flush=True)
    done(1)


def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT,
                                       timeout=10).decode(errors="replace").strip()
    except Exception as e:
        return "<err %s>" % e


def show_getters(o, tag):
    gs = sorted(m for m in dir(o) if m.startswith('get_'))
    for g in gs:
        try:
            v = getattr(o, g)()
        except Exception:
            continue
        if v is None:
            continue
        print("        %s.%s = %r" % (tag, g[4:], v), flush=True)


# ---------------------------------------------------------------- [1] device
def cb_bus(src, res, ud=None):
    try:
        S['bus'] = src.new_finish(res)
    except Exception as e:
        return fail("Qrtr.Bus.new_finish", e)
    L("bus up: %r" % (S['bus'],))
    node = S['bus'].get_node(NODE_ID)
    if node is None:
        return fail("bus.get_node(%d) -> None" % NODE_ID)
    S['node'] = node
    L("node %d: %d services; WDS port=%s DPM port=%s"
      % (NODE_ID, len(node.get_service_info_list()),
         node.lookup_port(1), node.lookup_port(Qmi.Service.DPM)))
    try:
        Qmi.Device.new_from_node(node, None, cb_dev, None)
    except Exception as e:
        fail("Qmi.Device.new_from_node call", e)


def cb_dev(src, res, ud=None):
    try:
        S['dev'] = Qmi.Device.new_from_node_finish(res)
    except Exception as e:
        return fail("Device.new_from_node_finish", e)
    L("device object path=%s" % S['dev'].get_path())
    try:
        S['dev'].open(Qmi.DeviceOpenFlags.NONE, 20, None, cb_opened, None)
    except Exception as e:
        fail("Device.open call", e)


def cb_opened(src, res, ud=None):
    try:
        src.open_finish(res)
    except Exception as e:
        return fail("Device.open_finish", e)
    L("device OPEN  is_open=%s" % src.is_open())
    L("rmnet_ipa0 BEFORE: %s"
      % sh("ip -o link show rmnet_ipa0 2>&1 | head -1"))
    # ---- [2] DPM client
    src.allocate_client(Qmi.Service.DPM, 0,
                        20, None, cb_dpm, None)


# ------------------------------------------------------------------- [2] DPM
def cb_dpm(src, res, ud=None):
    try:
        cli = src.allocate_client_finish(res)
    except Exception as e:
        return fail("allocate_client(DPM)", e)
    S['dpm'] = cli
    L("[2] DPM client  cid=%s" % cli.get_cid())
    Ele = Qmi.MessageDpmOpenPortInputHardwareDataPortsElement
    L("    element fields: %s" % sorted(m for m in dir(Ele) if not m.startswith('_')))
    try:
        # GI struct: fields are plain attributes, no setters on this type
        e = Ele()
        e.endpoint_type = Qmi.DataEndpointType.EMBEDDED
        e.interface_number = IFACE
        e.rx_endpoint_number = RX
        e.tx_endpoint_number = TX
        L("    elem: type=%s iface=%d rx=%d tx=%d"
          % (e.endpoint_type, e.interface_number, e.rx_endpoint_number,
             e.tx_endpoint_number))
        inp = Qmi.MessageDpmOpenPortInput.new()
        inp.set_hardware_data_ports([e])
    except Exception as exc:
        return fail("build DPM open_port input", exc)
    L("[2] -> dpm.open_port(EMBEDDED iface=%d rx=%d tx=%d)" % (IFACE, RX, TX))
    cli.open_port(inp, 20, None, cb_openport, None)


def cb_openport(src, res, ud=None):
    cli = S['dpm']
    try:
        out = cli.open_port_finish(res)
    except Exception as e:
        return fail("[2] dpm.open_port", e)
    L("[2] DPM open_port OK")
    show_getters(out, "dpm.open_port")
    # ---- [3] WDS client
    S['dev'].allocate_client(Qmi.Service.WDS, 0,
                             20, None, cb_wds, None)


# ------------------------------------------------------------------- [3] WDS
def cb_wds(src, res, ud=None):
    try:
        cli = src.allocate_client_finish(res)
    except Exception as e:
        return fail("allocate_client(WDS)", e)
    S['wds'] = cli
    L("[3] WDS client  cid=%s" % cli.get_cid())
    if BIND_MODE == "before":
        do_bind(cb_bind)
    elif BIND_MODE == "after":
        L("[3] bind_mux_data_port deferred until AFTER start_network")
        do_start()
    else:
        L("[3] bind_mux_data_port SKIPPED (BIND_MODE=none)")
        do_start()


def do_bind(cb):
    """Issue bind_mux_data_port(mux, EMBEDDED iface) and continue with cb."""
    cli = S['wds']
    try:
        b = Qmi.MessageWdsBindMuxDataPortInput.new()
        b.set_mux_id(MUX)
        b.set_endpoint_info(Qmi.DataEndpointType.EMBEDDED, IFACE)
    except Exception as exc:
        return fail("build bind_mux_data_port input", exc)
    L("    -> wds.bind_mux_data_port(mux_id=%d, EMBEDDED, iface=%d)"
      % (MUX, IFACE))
    cli.bind_mux_data_port(b, 20, None, cb, None)


def do_start():
    cli = S['wds']
    try:
        s = Qmi.MessageWdsStartNetworkInput.new()
        s.set_apn(APN)
        s.set_ip_family_preference(Qmi.WdsIpFamily.IPV4)
    except Exception as exc:
        return fail("build start_network input", exc)
    L("[4] -> wds.start_network(apn=%s, ipv4)" % APN)
    cli.start_network(s, 60, None, cb_start, None)


def cb_bind(src, res, ud=None):
    cli = S['wds']
    try:
        out = cli.bind_mux_data_port_finish(res)
    except Exception as e:
        return fail("[3] wds.bind_mux_data_port", e)
    L("[3] bind_mux_data_port OK")
    S['bound'] = True
    show_getters(out, "wds.bind")
    do_start()


def cb_bind_after(src, res, ud=None):
    """Bind issued *after* start_network succeeded."""
    cli = S['wds']
    try:
        out = cli.bind_mux_data_port_finish(res)
    except Exception as e:
        L("[3b] bind AFTER start_network FAILED: %s" % e)
        return step5()
    L("[3b] bind_mux_data_port (after start) OK")
    S['bound'] = True
    show_getters(out, "wds.bind.after")
    step5()


# ----------------------------------------------------------- [4] start_network
def cb_start(src, res, ud=None):
    cli = S['wds']
    try:
        out = cli.start_network_finish(res)
    except Exception as e:
        return fail("[4] wds.start_network", e)
    print("", flush=True)
    print("========== [4] START_NETWORK OK ==========", flush=True)
    show_getters(out, "wds.start")
    print("=========================================", flush=True)
    print("", flush=True)
    L("rmnet_ipa0 AFTER start: %s"
      % sh("ip -o link show rmnet_ipa0 2>&1 | head -1"))
    if BIND_MODE == "after" and not S.get('bound'):
        return do_bind(cb_bind_after)
    step5()


def step5():
    cli = S['wds']
    # ---- [5] current settings
    try:
        Rs = Qmi.WdsRequestedSettings
        mask = 0
        names = []
        for n in dir(Rs):
            if n.isupper():
                try:
                    v = int(getattr(Rs, n))
                except Exception:
                    continue
                if v:
                    mask |= v
                    names.append(n)
        L("    WdsRequestedSettings: %s  (mask=0x%x)" % (names, mask))
        gi_ = Qmi.MessageWdsGetCurrentSettingsInput.new()
        try:
            ok = gi_.set_requested_settings(Rs(mask))
        except Exception:
            ok = gi_.set_requested_settings(mask)
        L("    set_requested_settings(0x%x) -> %s" % (mask, ok))
    except Exception as exc:
        L("[5] cannot build get_current_settings input: %s" % exc)
        return hold()
    L("[5] -> wds.get_current_settings()")
    cli.get_current_settings(gi_, 30, None, cb_settings, None)


def _int2ip(n):
    """GI hands back QMI IPv4 values as host-order uint32 -> dotted quad."""
    n = int(n) & 0xFFFFFFFF
    return "%d.%d.%d.%d" % ((n >> 24) & 0xFF, (n >> 16) & 0xFF,
                            (n >> 8) & 0xFF, n & 0xFF)


def _pfxlen(mask):
    m = int(mask) & 0xFFFFFFFF
    n = 0
    while n < 32 and (m & (1 << (31 - n))):
        n += 1
    return n or 30


def _setting(out, *names):
    """First getter that exists and returns something non-None."""
    for n in names:
        f = getattr(out, n, None)
        if f is None:
            continue
        try:
            v = f()
        except Exception:
            continue
        if v is not None:
            return v
    return None


def cb_settings(src, res, ud=None):
    cli = S['wds']
    try:
        out = cli.get_current_settings_finish(res)
    except Exception as e:
        L("[5] get_current_settings FAILED: %s" % e)
        return hold()
    L("[5] get_current_settings OK")
    show_getters(out, "wds.settings")

    S['ipv4_address'] = _setting(out, "get_ipv4_address")
    S['gw'] = _setting(out, "get_ipv4_gateway_address")
    S['mask'] = _setting(out, "get_ipv4_gateway_subnet_mask",
                         "get_ipv4_subnet_mask")
    S['dns1'] = _setting(out, "get_primary_ipv4_dns_address",
                         "get_ipv4_primary_dns_address")
    S['dns2'] = _setting(out, "get_secondary_ipv4_dns_address",
                         "get_ipv4_secondary_dns_address")

    print("", flush=True)
    if S.get('ipv4_address'):
        A = _int2ip(S['ipv4_address'])
        P = _pfxlen(S['mask']) if S.get('mask') else 30
        G = _int2ip(S['gw']) if S.get('gw') else "?"
        S['addr_text'] = A
        S['pfx'] = P
        S['gw_text'] = G
        D1 = _int2ip(S['dns1']) if S.get('dns1') else "?"
        D2 = _int2ip(S['dns2']) if S.get('dns2') else "?"
        print(">>> CARRIER: IPv4 %s/%d   GW %s   DNS %s / %s"
              % (A, P, G, D1, D2), flush=True)
        print(">>>", flush=True)
        print(">>> *** rmnet_ipa0 is ARPHRD_RAWIP with header_ops == NULL and",
              flush=True)
        print(">>>     needs_headroom = sizeof(rmnet_map_header) (QMAP).",
              flush=True)
        print(">>>     IPv4 must NOT go on rmnet_ipa0 -- stack an rmnet vnd:",
              flush=True)
        print(">>>", flush=True)
        print(">>>   modprobe rmnet", flush=True)
        print(">>>   ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id %d"
              % MUX, flush=True)
        print(">>>   ip link set rmnet0 up", flush=True)
        print(">>>   ip addr add %s/%d dev rmnet0" % (A, P), flush=True)
        print(">>>   ping -I rmnet0 %s" % G, flush=True)
    else:
        print(">>> NO IPv4 in current settings.", flush=True)
        print(">>> Most common cause: radio is not online.  Check with",
              flush=True)
        print(">>>   qmicli -d qrtr://0 --dms-get-operating-mode", flush=True)
        print(">>> and fix with", flush=True)
        print(">>>   qmicli -d qrtr://0 --dms-set-operating-mode=online", flush=True)
        print(">>> (start_network ends with GENERIC_NO_SERVICE / CM 2001 if",
              flush=True)
        print(">>>  the mode is still 'shutting-down').", flush=True)
    print("", flush=True)
    stats_then_ping()



# --------------------------------------------------------------- round 67
# WDS packet statistics, queried on the client that actually holds the call.
def _stats_req(cb):
    """GI wants Qmi.MessageWdsGetPacketStatisticsInput with a mandatory Mask TLV."""
    try:
        gi_ = Qmi.MessageWdsGetPacketStatisticsInput.new()
    except Exception as e:
        L("cannot build get_packet_statistics input: %s" % e)
        return hold()
    try:
        Mk = Qmi.WdsPacketStatisticsMaskFlag
        mask = 0
        names = []
        for n in dir(Mk):
            if n.isupper():
                try:
                    v = int(getattr(Mk, n))
                except Exception:
                    continue
                if v:
                    mask |= v
                    names.append(n)
        try:
            gi_.set_mask(Mk(mask))
        except Exception:
            gi_.set_mask(mask)
        L("    WdsPacketStatisticsMask: %d bits (mask=0x%x)" % (len(names), mask))
    except Exception as e:
        L("cannot set statistics mask: %s" % e)
        return hold()
    S['wds'].get_packet_statistics(gi_, 30, None, cb, None)


def stats_then_ping():
    probe_pss()


def _stats_then_ping_real():
    L("[S1] -> wds.get_packet_statistics()   BEFORE traffic")
    _stats_req(cb_stats1)


def _dump_stats(out, tag):
    for name in ("get_tx_packets_ok", "get_rx_packets_ok",
                 "get_tx_packets_error", "get_rx_packets_error",
                 "get_tx_packets_dropped", "get_rx_packets_dropped",
                 "get_tx_bytes_ok", "get_rx_bytes_ok",
                 "get_last_call_tx_packets_ok",
                 "get_last_call_rx_packets_ok",
                 "get_last_call_tx_bytes_ok",
                 "get_last_call_rx_bytes_ok"):
        f = getattr(out, name, None)
        if f is None:
            continue
        try:
            v = f()
        except Exception as e:
            v = "err(%s)" % e
        if v is not None:
            print(">>> %s %-28s = %s" % (tag, name, v), flush=True)


def cb_stats1(src, res, ud=None):
    try:
        out = S['wds'].get_packet_statistics_finish(res)
    except Exception as e:
        L("[S1] get_packet_statistics FAILED: %s" % e)
        return hold()
    L("[S1] statistics BEFORE traffic")
    show_getters(out, "wds.stats.before")
    _dump_stats(out, "BEFORE")

    A = S.get('addr_text') or ""
    P = S.get('pfx') or 30
    G = S.get('gw_text') or ""
    if A:
        sh("ip addr flush dev rmnet0 2>/dev/null; "
           "ip link set rmnet0 up; "
           "ip addr add %s/%d dev rmnet0" % (A, P))
        L("rmnet0 now: %s" % sh("ip -o -4 addr show rmnet0 2>&1 | head -1"))
    L("AP counters BEFORE: %s" % sh(
        "ip -s link show rmnet0 | tr '\\n' ' '; "
        "ip -s link show rmnet_ipa0 | tr '\\n' ' '"))
    if G and G != "?":
        # NOT sh(): its 10 s ceiling truncated ping -c 10 and left us unable to
        # prove that anything was transmitted at all.
        L("ping 15 x %s via rmnet0 (the ONLY uplink test we have)" % G)
        try:
            r = subprocess.run(["ping", "-c", "15", "-W", "1", "-I",
                                "rmnet0", G],
                               capture_output=True, text=True, timeout=60)
            tail = [x for x in r.stdout.strip().splitlines() if x][-2:]
            print(">>> ping rc=%d" % r.returncode, flush=True)
            for x in tail:
                print(">>>   " + x, flush=True)
        except Exception as e:
            L("ping failed: %s" % e)
    else:
        L("no gateway -> no traffic; stats will still tell us the counters")
    ip_probe()

    L("AP counters AFTER:  %s" % sh(
        "ip -s link show rmnet0 | tr '\\n' ' '; "
        "ip -s link show rmnet_ipa0 | tr '\\n' ' '"))

    L("[S2] -> wds.get_packet_statistics()   AFTER traffic")
    _stats_req(cb_stats2)


def cb_stats2(src, res, ud=None):
    try:
        out = S['wds'].get_packet_statistics_finish(res)
    except Exception as e:
        L("[S2] get_packet_statistics FAILED: %s" % e)
        return hold()
    L("[S2] statistics AFTER traffic")
    show_getters(out, "wds.stats.after")
    _dump_stats(out, "AFTER ")
    print("", flush=True)
    print(">>> 判读：", flush=True)
    print(">>>   tx_packets_ok 增长 -> 上行真的发出去了，故障只在 IPA 下行", flush=True)
    print(">>>   tx_packets_ok 仍为 0 -> 承载根本没通，下行零帧是必然结果", flush=True)
    print(">>>   rx_packets_ok > 0 而 IPA evt=3 hw=0 -> modem 收到了但没交给 IPA", flush=True)
    print("", flush=True)

    # Z17S round 121: turn tx_packets_ok into a *repeatable* probe.
    # Until now the only statistics sample was the BEFORE/AFTER pair taken
    # during bring-up, so every later experiment (new QMI payloads, new
    # filter rules) was blind: ping is 100% loss either way and the IPA
    # status element only proves the TRE completed, not that the modem's
    # WDS bearer ever saw the packet.  A modem-side counter that moves is
    # the only thing that can tell those two apart.
    GLib.timeout_add_seconds(15, _z17s_periodic_stats)

    probe_dorm_after()


# ------------------------------------------------------------- round 121
# Periodic modem-side packet accounting.  Runs on the client that actually
# holds the call, so it does not hit QMI error 70 (InvalidOperation) the way
# an independent qmi_stats.py client does.
_z17s_tick = [0]


def _z17s_cb_stats(src, res, ud=None):
    try:
        out = S['wds'].get_packet_statistics_finish(res)
    except Exception as e:
        L("[T%02d] stats FAILED: %s" % (_z17s_tick[0], e))
        return False
    txp = _g(out, "get_tx_packets_ok")
    rxp = _g(out, "get_rx_packets_ok")
    txb = _g(out, "get_tx_bytes_ok")
    rxb = _g(out, "get_rx_bytes_ok")
    print(">>> [T%02d] tx_pkts_ok=%s rx_pkts_ok=%s tx_bytes=%s rx_bytes=%s"
          % (_z17s_tick[0], txp, rxp, txb, rxb), flush=True)
    return False


def _z17s_periodic_stats():
    _z17s_tick[0] += 1
    _stats_req(_z17s_cb_stats)
    return True


# ---------------------------------------------------------------- round 68
# 给 WDS 统计这个仪器做有效性检查。下面四个判据都不经过 IPA 的包计数器，
# 所以它们能独立回答"modem 到底有没有在空口发东西"。

def _g(out, *names):
    for n in names:
        f = getattr(out, n, None)
        if f is None:
            continue
        try:
            v = f()
        except Exception as e:
            v = "err(%s)" % e
        if v is not None:
            return v
    return None


def _dormant_text(v):
    try:
        return Qmi.WdsDormancyStatus(v).value_nick
    except Exception:
        return str(v)


def probe_pss():
    L("[P1] -> wds.get_packet_service_status()")
    # libqmi's GI signature carries a leading `unused` slot:/n    #   (unused, timeout, cancellable, callback, user_data)
    S['wds'].get_packet_service_status(None, 30, None, cb_pss, None)


def cb_pss(src, res, ud=None):
    try:
        out = S['wds'].get_packet_service_status_finish(res)
    except Exception as e:
        L("[P1] packet_service_status FAILED: %s" % e)
        return probe_dorm_before()
    L("[P1] packet_service_status OK")
    show_getters(out, "wds.pss")
    print(">>> [P1] PACKET SERVICE STATUS = %s"
          % _g(out, "get_status", "get_connection_status"), flush=True)
    probe_dorm_before()


def probe_dorm_before():
    L("[P2] -> wds.get_dormancy_status()   BEFORE traffic")
    S['wds'].get_dormancy_status(None, 30, None, cb_dorm1, None)


def cb_dorm1(src, res, ud=None):
    try:
        out = S['wds'].get_dormancy_status_finish(res)
    except Exception as e:
        L("[P2] dormancy FAILED: %s" % e)
        return probe_bearer()
    show_getters(out, "wds.dorm.before")
    v = _g(out, "get_status", "get_dormancy_status")
    S['dorm_before'] = v
    print(">>> [P2] DORMANCY BEFORE = %s (%s)"
          % (v, _dormant_text(v)), flush=True)
    probe_bearer()


def probe_bearer():
    L("[P3] -> wds.get_current_data_bearer_technology()")
    S['wds'].get_current_data_bearer_technology(None, 30, None, cb_bearer, None)


def cb_bearer(src, res, ud=None):
    try:
        out = S['wds'].get_current_data_bearer_technology_finish(res)
    except Exception as e:
        L("[P3] bearer tech FAILED: %s" % e)
        # NOT stats_then_ping(): that is now the head of this probe chain
        # and would recurse forever.  _stats_then_ping_real() is the body.
        return _stats_then_ping_real()
    show_getters(out, "wds.bearer")
    print(">>> [P3] BEARER now=%s last=%s"
          % (_g(out, "get_current_bearer", "get_current_data_bearer_technology"),
             _g(out, "get_last_bearer", "get_last_data_bearer_technology")),
          flush=True)
    _stats_then_ping_real()


def probe_dorm_after():
    L("[P4] -> wds.get_dormancy_status()   AFTER traffic")
    S['wds'].get_dormancy_status(None, 30, None, cb_dorm2, None)


def cb_dorm2(src, res, ud=None):
    try:
        out = S['wds'].get_dormancy_status_finish(res)
    except Exception as e:
        L("[P4] dormancy FAILED: %s" % e)
        return hold()
    show_getters(out, "wds.dorm.after")
    v = _g(out, "get_status", "get_dormancy_status")
    print(">>> [P4] DORMANCY AFTER  = %s (%s)"
          % (v, _dormant_text(v)), flush=True)
    b = S.get('dorm_before')
    if b is not None and v is not None and v != b:
        print(">>> [P4] 判读：dormancy 变了 => modem 真的在空口收发，"
              "WDS 计数器被 IPA offload 绕过", flush=True)
    elif v is not None:
        print(">>> [P4] 判读：dormancy 没变（%s）" % _dormant_text(v), flush=True)
    hold()


def _dns_pkt(qname="www.qualcomm.com"):
    import random as _r
    import struct as _st
    tid = _r.randint(0, 0xFFFF)
    q = b""
    for lab in qname.split("."):
        q += bytes([len(lab)]) + lab.encode()
    q += b"\x00"
    return tid, (_st.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + q
                 + _st.pack(">HH", 1, 1))


def ip_probe():
    """ICMP 可能被 APN 过滤，而且 ping 和 UDP 走的是同一条 QMAP 路径，
    所以这里再打两次：只要收到任何一个回包，就是本项目第一个下行帧。"""
    import socket
    ips = []
    for k in ("dns1", "dns2"):
        v = S.get(k)
        if v:
            ips.append(_int2ip(v))
    if not ips:
        print(">>> [P5] settings 里没有 DNS -> 跳过 UDP/TCP 探测", flush=True)
        return
    print(">>> [P5] DNS servers = %s" % ips, flush=True)
    for ip in ips:
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, 25, b"rmnet0\x00")  # SO_BINDTODEVICE
            s.settimeout(3)
            _tid, pkt = _dns_pkt()
            s.sendto(pkt, (ip, 53))
            data, peer = s.recvfrom(512)
            print(">>> [P5] UDP/53 %s -> GOT %d bytes from %s"
                  % (ip, len(data), peer), flush=True)
        except Exception as e:
            print(">>> [P5] UDP/53 %s -> %s" % (ip, e), flush=True)
        finally:
            try:
                if s is not None:
                    s.close()
            except Exception:
                pass
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, 25, b"rmnet0\x00")
            s.settimeout(3)
            rc = s.connect_ex((ip, 53))
            print(">>> [P5] TCP/53 %s -> connect_ex=%d" % (ip, rc), flush=True)
        except Exception as e:
            print(">>> [P5] TCP/53 %s -> %s" % (ip, e), flush=True)
        finally:
            try:
                if s is not None:
                    s.close()
            except Exception:
                pass


def hold():
    if HOLD <= 0:
        L("(hold=0 -> exiting; CID release will tear the call down)")
        return done(0)
    L("HOLDING %ds -- call stays up while this process lives" % HOLD)
    n = [0]

    def tick():
        n[0] += 1
        L("hold %d/%d  rmnet_ipa0: %s"
          % (n[0], HOLD, sh("ip -o -4 addr show rmnet_ipa0 2>&1 | head -1")))
        if n[0] >= HOLD:
            done(0)
            return False
        return True

    GLib.timeout_add_seconds(1, tick)


# ------------------------------------------------------------------- bootstrap
try:
    Qrtr.Bus.new(4000, None, cb_bus, None)
except Exception as e:
    print("FATAL Qrtr.Bus.new: %s" % e, flush=True)
    sys.exit(1)


def watchdog():
    print("[FAIL] global timeout (%ds)" % (HOLD + 120), flush=True)
    done(8)
    return False


GLib.timeout_add_seconds(HOLD + 120, watchdog)
loop.run()
L("exit rc=%d" % RC[0])
sys.exit(RC[0])
