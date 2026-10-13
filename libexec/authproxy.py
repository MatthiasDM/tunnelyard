#!/usr/bin/env python3
"""Authenticated SOCKS5 front-end that chains to an unauthenticated upstream
SOCKS5 proxy.

`vpn share` puts this in front of a tunnel's proxy so a shared connection
requires a username/password: only the person you hand the credential to can
use the forwarded proxy, even if others can reach the jump host it lands on.

It speaks SOCKS5 with RFC 1929 user/pass auth. For each authenticated client it
opens the upstream proxy, does the upstream's no-auth greeting, then splices the
two sockets -- the client's CONNECT request and everything after flow straight
through, because both ends speak plain SOCKS5 once the two greetings are done.
It never parses addresses, so hostname (socks5h) and IPv4/IPv6 requests all pass
through and are resolved inside the tunnel by the upstream, exactly as before.

The password comes from $SHARE_PROXY_PASS, never argv, to keep it out of `ps`.

    SHARE_PROXY_PASS=secret authproxy.py \
        --listen 127.0.0.1:21089 --upstream 127.0.0.1:1089 --user share
"""
import argparse
import os
import select
import socket
import sys
import threading


def recvn(sock, n):
    """Read exactly n bytes or raise EOFError."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def client_auth(conn, user, password):
    """Run the SOCKS5 greeting + RFC1929 user/pass exchange. True if it checks."""
    ver, nmethods = recvn(conn, 2)
    if ver != 5:
        return False
    recvn(conn, nmethods)                 # offered methods -- we dictate below
    conn.sendall(b"\x05\x02")             # choose username/password
    if recvn(conn, 1) != b"\x01":         # auth version
        return False
    ulen = recvn(conn, 1)[0]
    uname = recvn(conn, ulen)
    plen = recvn(conn, 1)[0]
    passwd = recvn(conn, plen)
    ok = uname == user.encode() and passwd == password.encode()
    conn.sendall(b"\x01" + (b"\x00" if ok else b"\x01"))
    return ok


def upstream_greet(up):
    """No-auth SOCKS5 greeting to the upstream proxy."""
    up.sendall(b"\x05\x01\x00")
    return recvn(up, 2) == b"\x05\x00"


def splice(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [])
            if a in r:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
            if b in r:
                d = b.recv(65536)
                if not d:
                    break
                a.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass


def handle(conn, user, password, up_host, up_port):
    up = None
    try:
        if not client_auth(conn, user, password):
            conn.close()
            return
        up = socket.create_connection((up_host, up_port), timeout=10)
        if not upstream_greet(up):
            conn.close()
            up.close()
            return
        splice(conn, up)
    except (EOFError, OSError):
        try:
            conn.close()
        except OSError:
            pass
        if up is not None:
            try:
                up.close()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="host:port to listen on")
    ap.add_argument("--upstream", required=True, help="host:port of the unauth SOCKS")
    ap.add_argument("--user", required=True)
    args = ap.parse_args()

    password = os.environ.get("SHARE_PROXY_PASS", "")
    if not password:
        print("authproxy: SHARE_PROXY_PASS not set", file=sys.stderr)
        sys.exit(2)

    lhost, lport = args.listen.rsplit(":", 1)
    uphost, upport = args.upstream.rsplit(":", 1)
    upport = int(upport)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lhost, int(lport)))
    srv.listen(64)
    print("authproxy: listening on %s, upstream %s" % (args.listen, args.upstream),
          file=sys.stderr)

    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        threading.Thread(
            target=handle,
            args=(conn, args.user, password, uphost, upport),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
