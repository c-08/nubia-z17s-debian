#!/usr/bin/env python3
# Enumerate QRTR services on node 0 (read-only, no QMI traffic)
import gi, sys
gi.require_version('Qrtr', '1.0')
from gi.repository import Qrtr, GLib

loop = GLib.MainLoop()
BUS = [None]


def cb_bus(src, res, ud=None):
    try:
        BUS[0] = src.new_finish(res)
    except Exception as e:
        print("bus fail: %s" % e)
        loop.quit()
        return
    loop.quit()


print("Info getters:", [m for m in dir(Qrtr.NodeServiceInfo) if m.startswith('get_')])
Qrtr.Bus.new(4000, None, cb_bus, None)
GLib.timeout_add_seconds(20, lambda: loop.quit())
loop.run()

bus = BUS[0]
if bus is None:
    print("no bus")
    sys.exit(1)

for n in bus.get_nodes():
    nid = n.get_id()
    lst = n.get_service_info_list()
    print("")
    print("### node %d  (%d services)" % (nid, len(lst)))
    rows = []
    for si in lst:
        try:
            rows.append((si.get_service(), si.get_port(), si.get_version()))
        except Exception as e:
            rows.append(("?", "?", str(e)))
    for svc, port, ver in sorted(rows, key=lambda r: (r[0] if isinstance(r[0], int) else 999)):
        print("   service=%-4s port=%-5s ver=%s" % (svc, port, ver))

node0 = bus.get_node(0)
print("")
print("--- probe lookup_service() on node 0 for candidate ids ---")
for sid in (1, 2, 3, 4, 5, 11, 15, 16, 31, 41, 45, 47, 49, 51, 66, 69):
    try:
        print("   lookup_service(%3d) -> %s" % (sid, node0.lookup_service(sid)))
    except Exception as e:
        print("   lookup_service(%3d) !! %s" % (sid, e))
sys.exit(0)
