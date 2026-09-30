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

print("=== single-process QMI  apn=%s tx=%d rx=%d iface=%d mux=%d hold=%d ==="
      % (APN, TX, RX, IFACE, MUX, HOLD), flush=True)

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
    try:
        b = Qmi.MessageWdsBindMuxDataPortInput.new()
        b.set_mux_id(MUX)
        b.set_endpoint_info(Qmi.DataEndpointType.EMBEDDED, IFACE)
    except Exception as exc:
        return fail("build bind_mux_data_port input", exc)
    L("[3] -> wds.bind_mux_data_port(mux_id=%d, EMBEDDED, iface=%d)" % (MUX, IFACE))
    cli.bind_mux_data_port(b, 20, None, cb_bind, None)


def cb_bind(src, res, ud=None):
    cli = S['wds']
    try:
        out = cli.bind_mux_data_port_finish(res)
    except Exception as e:
        return fail("[3] wds.bind_mux_data_port", e)
    L("[3] bind_mux_data_port OK")
    show_getters(out, "wds.bind")
    try:
        s = Qmi.MessageWdsStartNetworkInput.new()
        s.set_apn(APN)
        s.set_ip_family_preference(Qmi.WdsIpFamily.IPV4)
    except Exception as exc:
        return fail("build start_network input", exc)
    L("[4] -> wds.start_network(apn=%s, ipv4)" % APN)
    cli.start_network(s, 60, None, cb_start, None)


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


def cb_settings(src, res, ud=None):
    cli = S['wds']
    try:
        out = cli.get_current_settings_finish(res)
    except Exception as e:
        L("[5] get_current_settings FAILED: %s" % e)
        return hold()
    L("[5] get_current_settings OK")
    show_getters(out, "wds.settings")
    ip = None
    for g in ("get_ipv4_address", "get_ipv4_gateway_address",
              "get_ipv4_subnet_mask",
              "get_ipv4_primary_dns_address", "get_ipv4_secondary_dns_address"):
        try:
            v = getattr(out, g)()
        except Exception:
            continue
        if v is None:
            continue
        S[g[4:]] = v
    if S.get('ipv4_address'):
        print("", flush=True)
        print(">>> ASSIGN:  ip addr add %s/%s dev rmnet_ipa0"
              % (S['ipv4_address'], S.get('ipv4_subnet_mask', '?')))
        print(">>> GATEWAY: %s    DNS: %s / %s"
              % (S.get('ipv4_gateway_address'), S.get('ipv4_primary_dns_address'),
                 S.get('ipv4_secondary_dns_address')), flush=True)
        print("", flush=True)
    hold()


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
