#!/usr/bin/env python3
"""
z17s-proxy.py -- a tiny, dependency-free HTTP/HTTPS forward proxy for the Z17S.

Why this exists
---------------
The phone's normal internet path is Windows ICS on the USB RNDIS link
(PC 192.168.137.1 -> NAT -> phone 192.168.137.2).  ICS is admin-only and its NAT
binding occasionally goes stale.  This proxy is the *no-admin* fallback: it runs as
an ordinary user process on the PC and lets the phone reach the internet through it.

The phone then uses it like this:
    export http_proxy=http://192.168.137.1:3128
    export https_proxy=http://192.168.137.1:3128
    # for the docker daemon, put it in /etc/docker/daemon.json:
    #   { "proxies": { "http-proxy": "http://192.168.137.1:3128",
    #                  "https-proxy": "http://192.168.137.1:3128",
    #                  "no-proxy": "localhost,127.0.0.1,192.168.137.0/24,192.168.1.0/24" } }

Usage:
    python z17s-proxy.py [--bind 0.0.0.0] [--port 3128]
"""

import argparse
import select
import socket
import socketserver
import sys
import threading
import time

BUFSIZE = 65536
TIMEOUT = 600


def log(msg: str) -> None:
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)


# --------------------------------------------------------------------------- DNS
# An HTTP proxy carries TCP only, so the phone still needs a resolver when its wifi
# (and therefore its DHCP-provided nameserver 192.168.1.1) is down.  This is a dumb
# UDP relay: forward the raw query to an upstream resolver and hand back the raw
# answer, no parsing.  Windows lets a non-admin process bind :53, which makes this a
# complete no-admin fallback together with the proxy above.
class DnsHandler(socketserver.BaseRequestHandler):
    upstream = "223.5.5.5"

    def handle(self) -> None:
        data, sock = self.request
        if not data:
            return
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as up:
                up.settimeout(5)
                up.sendto(data, (self.upstream, 53))
                answer, _ = up.recvfrom(4096)
            sock.sendto(answer, self.client_address)
        except OSError as exc:
            log(f"DNS {self.client_address[0]} -> {self.upstream} failed: {exc}")


class ThreadedUdpServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


def start_dns_relay(port: int, upstream: str) -> bool:
    DnsHandler.upstream = upstream
    for bind in ("0.0.0.0", "192.168.137.1"):
        try:
            srv = ThreadedUdpServer((bind, port), DnsHandler)
        except OSError as exc:
            log(f"DNS relay: cannot bind udp/{bind}:{port}: {exc}")
            continue
        t = threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.5},
                             daemon=True)
        t.start()
        log(f"DNS relay listening on udp/{bind}:{port} -> {upstream}")
        return True
    log("DNS relay disabled (port 53 unavailable -- that is normal while ICS is active, "
        "because ICS owns 192.168.137.1:53)")
    return False


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.settimeout(TIMEOUT)
        try:
            head = self._read_head()
        except Exception as exc:                                  # noqa: BLE001
            log(f"head read failed from {self.client_address[0]}: {exc}")
            return
        if not head:
            return

        try:
            first = head.split(b"\r\n", 1)[0].decode("latin-1")
        except Exception:                                          # noqa: BLE001
            return
        parts = first.split()
        if len(parts) < 2:
            return
        method, target = parts[0].upper(), parts[1]

        if method == "CONNECT":
            self._do_connect(head, target)
        else:
            self._do_forward(head, method, target)

    # ------------------------------------------------------------------ helpers
    def _read_head(self) -> bytes:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.request.recv(BUFSIZE)
            if not chunk:
                break
            buf += chunk
            if len(buf) > 1 << 20:
                break
        return buf

    @staticmethod
    def _split_hostport(target: str, default_port: int = 80):
        if target.startswith("["):                    # [v6]:port
            host, _, rest = target[1:].partition("]")
            port = int(rest[1:]) if rest.startswith(":") else default_port
            return host, port
        if ":" in target:
            host, _, p = target.rpartition(":")
            if p.isdigit():
                return host, int(p)
        return target, default_port

    def _pump(self, sock_a: socket.socket, sock_b: socket.socket) -> None:
        """Copy bytes both ways until either side closes.

        Deliberately *blocking* sockets, one thread per direction.  An earlier
        select()+non-blocking version was wrong: sendall() raises BlockingIOError
        (an OSError subclass) the moment the peer's window fills, which the caller
        treated as fatal and tore the tunnel down.  Small responses survived, but
        docker pulls died with "EOF" mid token exchange.  Blocking sendall does the
        waiting for us and cannot partially send.
        """
        for s in (sock_a, sock_b):
            try:
                s.setblocking(True)
                s.settimeout(TIMEOUT)
            except OSError:
                pass

        def relay(src: socket.socket, dst: socket.socket) -> None:
            try:
                while True:
                    try:
                        data = src.recv(BUFSIZE)
                    except (socket.timeout, OSError):
                        break
                    if not data:
                        break
                    try:
                        dst.sendall(data)
                    except OSError:
                        break
            finally:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        t = threading.Thread(target=relay, args=(sock_a, sock_b), daemon=True)
        t.start()
        relay(sock_b, sock_a)
        t.join(timeout=5)

    # ------------------------------------------------------------------ CONNECT
    def _do_connect(self, head: bytes, target: str) -> None:
        host, port = self._split_hostport(target, 443)
        try:
            upstream = socket.create_connection((host, port), timeout=15)
        except OSError as exc:
            log(f"CONNECT {host}:{port} FAILED: {exc}")
            try:
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            except OSError:
                pass
            return
        log(f"CONNECT {host}:{port} OK")
        try:
            self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        except OSError:
            upstream.close()
            return
        # anything already buffered after the head
        rest = head.split(b"\r\n\r\n", 1)
        if len(rest) == 2 and rest[1]:
            try:
                upstream.sendall(rest[1])
            except OSError:
                pass
        try:
            self._pump(self.request, upstream)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    # -------------------------------------------------------- plain HTTP proxy
    def _do_forward(self, head: bytes, method: str, target: str) -> None:
        if not target.lower().startswith("http://"):
            try:
                self.request.sendall(
                    b"HTTP/1.1 400 Bad Request\r\n\r\nonly absolute-form http:// is proxied\r\n"
                )
            except OSError:
                pass
            return
        hostport, _, path = target[len("http://"):].partition("/")
        path = "/" + path
        host, port = self._split_hostport(hostport, 80)
        try:
            upstream = socket.create_connection((host, port), timeout=15)
        except OSError as exc:
            log(f"{method} {host}:{port} FAILED: {exc}")
            try:
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            except OSError:
                pass
            return
        log(f"{method} {host}:{port}{path}")
        try:
            lines = head.split(b"\r\n")
            out = [lines[0]]
            for ln in lines[1:]:
                if not ln:
                    continue
                low = ln.lower()
                if low.startswith(b"proxy-connection:") or low.startswith(b"connection:"):
                    continue
                out.append(ln)
            out.append(b"Connection: close")
            out.append(b"")
            out.append(b"")
            upstream.sendall(b"\r\n".join(out))
            self._pump(self.request, upstream)
        finally:
            try:
                upstream.close()
            except OSError:
                pass


class ThreadedServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=3128)
    ap.add_argument("--dns-port", type=int, default=53, help="0 disables the DNS relay")
    ap.add_argument("--dns-upstream", default="223.5.5.5")
    args = ap.parse_args()

    if args.dns_port:
        start_dns_relay(args.dns_port, args.dns_upstream)

    try:
        srv = ThreadedServer((args.bind, args.port), Handler)
    except OSError as exc:
        log(f"cannot listen on {args.bind}:{args.port}: {exc}")
        return 1

    log(f"z17s-proxy listening on {args.bind}:{args.port}")
    log("phone side:")
    log(f"  export http_proxy=http://192.168.137.1:{args.port}")
    log(f"  export https_proxy=http://192.168.137.1:{args.port}")
    if args.dns_port:
        log("  nmcli con mod z17s-usb0 ipv4.dns 192.168.137.1   # proxy mode = no NAT, DNS must use this relay")
        log("  nmcli device reapply usb0                          # do NOT hand-edit /etc/resolv.conf")
    log("Ctrl-C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("stopping")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
