#!/usr/bin/env python3
"""Pure-TCP CONNECT relay. Listens on 0.0.0.0:443 and :7844; maps the
destination 127.0.0.x (set via /etc/hosts bind-mount) back to a hostname
and opens an HTTP CONNECT tunnel through the sandbox egress proxy.
Transparent byte splice afterwards (works for TLS + HTTP/2)."""
import socket, threading, select, os, sys, base64
from urllib.parse import urlparse

# 127.0.0.x -> LIST IP ASLI edge Cloudflare (via DNS-over-HTTPS).
# PENTING: jangan pakai hostname di sini — DNS proxy me-hijack hostname
# Cloudflare ke IP palsu sehingga CONNECT ke :7844 hang. CONNECT langsung
# ke IP asli lolos (terverifikasi 2026-10-05).
# Nilai berupa list: koneksi ke :7844 via proxy flaky (kadang hang per-IP),
# jadi relay mencoba tiap IP berurutan sampai ada yang tembus.
MAP = {
    "127.0.0.2": ["104.16.230.132", "104.16.231.132"],  # api.trycloudflare.com
    "127.0.0.3": ["198.41.192.77", "198.41.192.57", "198.41.192.7",
                  "198.41.192.167", "198.41.192.37"],   # region1.v2.argotunnel.com
    "127.0.0.4": ["198.41.200.233", "198.41.200.43", "198.41.200.23",
                  "198.41.200.63", "198.41.200.13"],    # region2.v2.argotunnel.com
}
LISTEN_PORTS = (443, 7844)

def get_proxy():
    u = (os.environ.get("SHIM_PROXY") or os.environ.get("https_proxy")
         or os.environ.get("HTTPS_PROXY") or os.environ.get("http_proxy") or "")
    p = urlparse(u)
    auth = None
    if p.username:
        auth = base64.b64encode(
            ("%s:%s" % (p.username, p.password or "")).encode()).decode()
    return p.hostname, p.port or 3128, auth

PX_HOST, PX_PORT, PX_AUTH = get_proxy()
if not PX_HOST:
    sys.stderr.write("no proxy in env\n"); sys.exit(1)
PX_IP = socket.getaddrinfo(PX_HOST, PX_PORT, socket.AF_INET,
                           socket.SOCK_STREAM)[0][4][0]
sys.stderr.write("relay up on %s\n" % (LISTEN_PORTS,))

def connect_via_proxy(hosts, port):
    """hosts: satu IP atau list IP. Coba berurutan sampai CONNECT 200."""
    if isinstance(hosts, str):
        hosts = [hosts]
    last_err = RuntimeError("no candidate IPs")
    for host in hosts:
        try:
            s = socket.create_connection((PX_IP, PX_PORT), timeout=15)
            s.settimeout(30)  # CONNECT ke :7844 via proxy bisa lambat
            req = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n" % (host, port, host, port)
            if PX_AUTH:
                req += "Proxy-Authorization: Basic %s\r\n" % PX_AUTH
            req += "\r\n"
            s.sendall(req.encode())
            resp = b""
            while b"\r\n\r\n" not in resp:
                ch = s.recv(4096)
                if not ch:
                    raise RuntimeError("proxy closed")
                resp += ch
                if len(resp) > 8192:
                    raise RuntimeError("proxy resp too big")
            if b" 200" not in resp.split(b"\r\n", 1)[0]:
                raise RuntimeError("proxy refused: %s" % resp.split(b"\r\n")[0])
            s.settimeout(None)  # kembali blocking untuk splice
            return s
        except Exception as e:
            last_err = e
            sys.stderr.write("relay CONNECT %s:%d gagal: %s\n" % (host, port, e))
            try:
                s.close()
            except Exception:
                pass
    raise last_err

def splice(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 180)
            if not r:
                break
            for s in r:
                d = s.recv(65536)
                if not d:
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.close()
            except Exception: pass

def handle(client):
    try:
        dst_ip, dst_port = client.getsockname()[0], client.getsockname()[1]
        host = MAP.get(dst_ip)
        if not host:
            client.close(); return
        sys.stderr.write("relay %s:%d -> %s:%d\n" % (dst_ip, dst_port, host, dst_port))
        up = connect_via_proxy(host, dst_port)
        splice(client, up)
    except Exception as e:
        sys.stderr.write("relay error: %s\n" % e)
        try: client.close()
        except Exception: pass

def serve(port):
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("0.0.0.0", port))
    ls.listen(100)
    while True:
        c, _ = ls.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

for p in LISTEN_PORTS:
    threading.Thread(target=serve, args=(p,), daemon=True).start()
threading.Event().wait()
