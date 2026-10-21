#!/opt/cpyvpn/bin/python3
"""Check Point connector for the tunnelyard image, built on cpyvpn.

cpyvpn (GPLv3, https://gitlab.com/cpvpn/cpyvpn) is a pure-Python Check Point
client. It speaks the CCC/SLIM protocol of Check Point's own Endpoint Security
and Capsule clients -- login options, a certificate or password first factor,
a multi-challenge second factor, then an SSL Network Extender tunnel over 443
-- and it can also log in through a Mobile Access portal.

This wrapper exists for two reasons.

1. cpyvpn 1.6.4's vpnc-script mode (`-s`) is broken. VNAVPNC.run_vpnc puts
   INTERNAL_IP4_ADDRESS / INTERNAL_IP4_NETMASK / VPNGATEWAY into the keyword
   arguments of subprocess.run instead of the script's environment, and reads
   self.gw at pre-init, before set_ips has run, so it dies with
   AttributeError before the first request to the gateway. The replacement
   below passes those variables where vpnc-script expects them, and starts
   from the current environment so the script keeps PATH plus the VPN_NAME /
   VPN_ROUTE_DNS that vpnc-wrapper reads. Network Manager mode, upstream's
   default, is not an option inside a container.

2. Two modes the stock client lacks and this image wants:

     --login-options    ask the gateway what it accepts (realms, factor types,
                        prompt labels) and exit. Nothing is authenticated, so
                        it is safe for a customer you cannot log in to yet.
                        `tunnelyard probe <customer>` runs this.

     VPN_AUTH_ONLY=1    authenticate, print the route ranges the gateway grants
                        the session, sign out, and exit without building a
                        tunnel -- the same split `tunnelyard auth` gives
                        openconnect customers.

Everything else is cp_client unchanged: arguments pass straight through.
"""
import json
import logging
import os
import shlex
import ssl
import subprocess
import sys
from urllib import error

from cpyvpn import auth, client, ssl_ctx, utils, vna

log = logging.getLogger()


# --- 1. repair the vpnc-script adapter --------------------------------------

def run_vpnc(self, reason):
    env = dict(os.environ)
    env.update(self._env)
    env["reason"] = reason
    addr = self.om_ip()
    if addr:
        env["INTERNAL_IP4_ADDRESS"] = addr
    if self.netmask:
        env["INTERNAL_IP4_NETMASK"] = self.netmask
    gw = getattr(self, "gw", None)
    if gw:
        env["VPNGATEWAY"] = gw
    # Output is left on stderr on purpose: vpnc-wrapper logs the DNS routes it
    # adds, and a failing script should say why.
    subprocess.run(shlex.split(self._vpnc), env=env, stdin=subprocess.DEVNULL, check=True)


vna.VNAVPNC.run_vpnc = run_vpnc


# --- 2. --login-options -----------------------------------------------------

def login_options(argv):
    loglevel = "INFO"
    rest = []
    it = iter(argv)
    for a in it:
        if a == "--loglevel":
            loglevel = next(it, loglevel)
        elif a.startswith("--loglevel="):
            loglevel = a.split("=", 1)[1]
        else:
            rest.append(a)
    server = next((a for a in reversed(rest) if not a.startswith("-")), None)
    if not server:
        sys.exit("usage: checkpoint-client --login-options [--loglevel DEBUG] <gateway>")

    logging.basicConfig(level=getattr(logging, loglevel.upper(), logging.INFO),
                        stream=sys.stdout, format="%(message)s")
    p = utils.parseurl(server)
    gw = "{}:{}".format(p.host, p.port)
    ssl_ctx.check_ssl_mode(p.host, p.port, False)

    # The same ClientHello cp_client opens with. It carries no identity.
    try:
        rd = utils.do_ccc_request(gw + "/clients", data=auth.SNXAuth.CCCClientHello).find("ResponseData")
    except error.HTTPError as e:
        sys.exit("gateway answered HTTP {} to the CCC ClientHello at /clients -- "
                 "not a Check Point remote-access endpoint?".format(e.code))

    pv = (rd.get("protocol_version") or {}).get("protocol_version")
    ci = rd.get("connectivity_info") or {}
    print("gateway             : {}".format(gw))
    print("protocol_version    : {}".format(pv))
    for k in ("server_ip", "connect_with_certificate_url", "cookie_name",
              "supported_data_tunnel_transports", "tcpt_port", "natt_port",
              "internal_ca_fingerprint"):
        if k in ci:
            v = ci[k]
            if not isinstance(v, str):
                v = json.dumps(v, ensure_ascii=False)
            print("{:<20}: {}".format(k, v))

    opts = (rd.get("login_options_data") or {}).get("login_options_list") or {}
    print("login options       : {}".format(len(opts)))
    for key, o in opts.items():
        print("  [{}] id={} display_name={!r} show_realm={}".format(
            key, o.get("id"), o.get("display_name"), o.get("show_realm")))
        for fi, f in sorted((o.get("factors") or {}).items()):
            extra = ""
            labels = f.get("custom_display_labels") or {}
            if labels:
                extra += " labels={}".format(json.dumps(dict(labels), ensure_ascii=False))
            if f.get("securid_card_type"):
                extra += " securid_card_type={}".format(f["securid_card_type"])
            print("      factor {}: {}{}".format(fi, f.get("factor_type"), extra))
    print()
    print("full ClientHello response:")
    print(json.dumps(rd, indent=2, ensure_ascii=False))


# --- 3. VPN_AUTH_ONLY=1 -----------------------------------------------------

def install_auth_only():
    orig_ranges = utils.get_ranges
    orig_sd = auth.SNXAuth.get_session_data

    def get_ranges(url, sid):
        rl = orig_ranges(url, sid)
        if rl:
            log.info("auth-only: route ranges granted to this session:")
            for r in rl:
                log.info("auth-only:   %s - %s", r.get("from"), r.get("to"))
        else:
            log.info("auth-only: gateway sent no route ranges before hello")
        return rl

    def get_session_data(self):
        sd = orig_sd(self)
        log.info("auth-only: AUTHENTICATED -- %s:%s granted a session; not building a tunnel",
                 sd.host, sd.port)
        # Unwinds through cpyvpn's ExitStack, which signs the session out.
        raise SystemExit(0)

    utils.get_ranges = get_ranges
    auth.SNXAuth.get_session_data = get_session_data


def main():
    argv = sys.argv[1:]
    if "--login-options" in argv:
        login_options([a for a in argv if a != "--login-options"])
        return
    if os.environ.get("VPN_AUTH_ONLY") == "1":
        install_auth_only()
    try:
        client.main()
    except ssl.SSLError as e:
        # A gateway that does not trust the client certificate drops the TLS
        # handshake on its certificate-login URL instead of answering; the
        # resulting traceback says nothing useful. Verified against a real
        # gateway with a self-signed certificate: SSLV3_ALERT_HANDSHAKE_FAILURE.
        log.error("TLS handshake refused by the gateway: %s", e)
        if os.environ.get("VPN_CERT"):
            log.error("The gateway does not accept this client certificate: wrong "
                      "certificate, or the PEM lacks the issuing (intermediate) CA "
                      "certificates -- append them to the PEM, below the key.")
        sys.exit(1)


if __name__ == "__main__":
    main()
