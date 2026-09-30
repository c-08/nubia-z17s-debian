#!/usr/bin/env python3
# Probe v2: Bus.new(ms) -> bus -> node -> Qmi.Device.new_from_node -> open
import gi, sys
gi.require_version('Qrtr', '1.0')
gi.require_version('Qmi', '1.0')
from gi.repository import Qrtr, Qmi, GLib, Gio

loop = GLib.MainLoop()
state = {'rc': 9, 'done': False}


def stop(code=0):
    if not state['done']:
        state['done'] = True
        state['rc'] = code
        loop.quit()


def T(label, fn):
    try:
        v = fn()
        print("  OK   %-44s -> %r" % (label, v))
        return v
    except Exception as e:
        print("  FAIL %-44s -> %s: %s" % (label, type(e).__name__, e))
        return None


BUS = [None]
DEV = [None]


def cb_bus(src, res, ud=None):
    try:
        BUS[0] = src.new_finish(res)
    except Exception as e:
        print("  FAIL Bus.new_finish -> %s" % e)
        return stop(1)
    print("  OK   Bus.new_finish -> %r" % (BUS[0],))
    step_b()


def step_b():
    bus = BUS[0]
    print("== B. nodes ==")
    nodes = T("bus.get_nodes()", lambda: bus.get_nodes())
    if nodes:
        for n in nodes:
            print("     node id=%s services=%r" % (n.get_id(), n.get_service_info_list()))
    node = T("bus.get_node(0)", lambda: bus.get_node(0))
    T("bus.peek_node(0)", lambda: bus.peek_node(0))
    if node is None:
        print("  -- get_node(0) None, try wait_for_node(0, 3000) sync-ish")
        try:
            node = bus.wait_for_node(0, 3000, None, None)
            print("  OK   wait_for_node -> %r" % (node,))
        except Exception as e:
            print("  FAIL wait_for_node (async form) -> %s" % e)
    if node is None and nodes:
        node = nodes[0]
    if node is None:
        print("  !! no node")
        return stop(1)

    print("== C. node ==")
    T("node.get_id()", lambda: node.get_id())
    T("node.lookup_service(1=WDS)", lambda: node.lookup_service(1))
    T("node.lookup_service(47=DPM)", lambda: node.lookup_service(47))
    T("node.wait_for_services(3000,None)", lambda: node.wait_for_services(3000, None))
    print("     services after wait: %r" % (node.get_service_info_list(),))

    print("== D. Qmi.Device.new_from_node ==")

    def cb_dev(src, res, ud=None):
        try:
            DEV[0] = src.__class__.new_from_node_finish(res)
        except Exception as e:
            print("  FAIL new_from_node_finish -> %s" % e)
            return stop(1)
        d = DEV[0]
        print("  OK   new_from_node_finish -> %r node=%s path=%s"
              % (d, d.get_node().get_id() if d.get_node() else "?",
                 T("dev.get_path()", lambda: d.get_path())))
        step_open()

    try:
        Qmi.Device.new_from_node(node, None, cb_dev)
    except Exception as e:
        print("  FAIL new_from_node call -> %s" % e)
        stop(1)


def step_open():
    print("== E. Device.open ==")

    def cb_open(src, res, ud=None):
        try:
            src.open_finish(res)
        except Exception as e:
            print("  FAIL open_finish -> %s" % e)
            return stop(1)
        print("  OK   open_finish  is_open=%s" % src.is_open())
        T("get_expected_data_format()", lambda: src.get_expected_data_format())
        stop(0)

    for flag, name in ((Qmi.DeviceOpenFlags.NONE, "NONE"),
                       (Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, "EXPECT_INDICATIONS")):
        print("  -- open flags=%s" % name)
        try:
            DEV[0].open(flag, 15, None, cb_open)
            return
        except Exception as e:
            print("     call failed: %s" % e)
    stop(1)


print("== A. Qrtr.Bus.new(4000) ==")
try:
    Qrtr.Bus.new(4000, None, cb_bus, None)
except Exception as e:
    print("  FATAL Bus.new -> %s" % e)
    stop(1)


def watchdog():
    print("[FAIL] global timeout 45s")
    stop(9)
    return False


GLib.timeout_add_seconds(45, watchdog)
loop.run()
print("== done rc=%d ==" % state['rc'])
sys.exit(0)
