#!/bin/sh
# Runs one customer VPN inside this container's network namespace and exposes it
# to the host as a SOCKS5 proxy plus any fixed TCP forwards.
#
# Driven entirely by environment (see customers/_template.env).
set -eu

NAME="${VPN_NAME:-vpn}"

log() { printf '[%s] %s\n' "$NAME" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- plumbing ---------------------------------------------------------------

ensure_tun() {
    if [ -c /dev/net/tun ]; then
        return 0
    fi
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 \
        || die "cannot create /dev/net/tun -- container needs --cap-add=NET_ADMIN"
    chmod 600 /dev/net/tun
    log "created /dev/net/tun"
}

start_socks() {
    # Always 1080 inside the container; the host-side port is chosen by bin/tunnelyard
    # from SOCKS_PORT so each customer gets a distinct localhost port.
    microsocks -i 0.0.0.0 -p "${SOCKS_LISTEN:-1080}" &
    log "socks5 listening on :${SOCKS_LISTEN:-1080}"
}

# FORWARDS="2575:10.20.5.40:2575,2222:10.20.5.41:22"
start_forwards() {
    [ -n "${FORWARDS:-}" ] || return 0
    _oldifs="$IFS"
    IFS=','
    for fwd in $FORWARDS; do
        IFS="$_oldifs"
        if [ -n "$fwd" ]; then
            lport="${fwd%%:*}"
            rest="${fwd#*:}"
            rhost="${rest%:*}"
            rport="${rest##*:}"
            if [ "$rest" = "$fwd" ] || [ -z "$rhost" ] || [ -z "$rport" ]; then
                die "bad FORWARDS entry '$fwd' (expected lport:host:rport)"
            fi
            socat "TCP-LISTEN:${lport},fork,reuseaddr" "TCP:${rhost}:${rport}" &
            log "forward :${lport} -> ${rhost}:${rport}"
        fi
        IFS=','
    done
    IFS="$_oldifs"
}

# Hold the gateway's idle timer open.
#
# Gateways like F5 APM expire a session on lack of *user* traffic, and the
# client's own protocol keepalives do not count: openconnect happily keeps its
# DTLS transport up while the session behind it has already been reaped, which
# leaves a tunnel that looks healthy and blackholes everything. So send real
# traffic through the tunnel on an interval comfortably under the server's
# timeout.
#
# KEEPALIVE_TARGET defaults to the first FORWARDS entry -- by definition a host
# this tunnel is supposed to reach. Set KEEPALIVE_INTERVAL=0 (the default) to
# leave a customer alone.
start_keepalive() {
    _iv="${KEEPALIVE_INTERVAL:-0}"
    case "$_iv" in ''|*[!0-9]*) _iv=0 ;; esac
    [ "$_iv" -gt 0 ] || return 0

    _tgt="${KEEPALIVE_TARGET:-}"
    if [ -z "$_tgt" ] && [ -n "${FORWARDS:-}" ]; then
        _first="${FORWARDS%%,*}"
        _rest="${_first#*:}"
        [ "$_rest" != "$_first" ] && _tgt="$_rest"
    fi
    if [ -z "$_tgt" ]; then
        log "keepalive: no KEEPALIVE_TARGET and no FORWARDS to borrow one from -- disabled"
        return 0
    fi

    _kh="${_tgt%:*}"
    _kp="${_tgt##*:}"
    if [ -z "$_kh" ] || [ -z "$_kp" ] || [ "$_kh" = "$_kp" ]; then
        log "keepalive: bad target '$_tgt' (expected host:port) -- disabled"
        return 0
    fi

    # Only failures are logged. A line every interval would push the useful
    # connection history out of `tunnelyard logs --tail`.
    (
        while :; do
            sleep "$_iv"
            socat -T3 /dev/null "TCP:${_kh}:${_kp},connect-timeout=3" >/dev/null 2>&1 \
                || log "keepalive: ${_kh}:${_kp} did not answer"
        done
    ) &
    log "keepalive: every ${_iv}s to ${_kh}:${_kp}"
}

# Keep the F5 APM *session* alive, and record what it is doing.
#
# The data-path keepalive above is not enough for every gateway: Riverside expires
# a session after 15 idle minutes even while real TCP traffic crosses the tunnel
# every 4 minutes, which means it is not counting tunnel traffic at all. F5 APM
# tracks activity against the APM session -- the MRHSession cookie, at the HTTP
# layer -- so refresh it there, on the gateway's public address, outside the
# tunnel.
#
# Each poll also logs a verdict, which is what makes a stale tunnel diagnosable
# after the fact: "APM SESSION EXPIRED" means the session was reaped underneath
# a working transport, while "session ok" alongside a frozen rx counter means
# the session outlived the data path and the transport is at fault instead.
start_f5_session_keepalive() {
    _ck="$1"
    _iv="${F5_SESSION_KEEPALIVE:-0}"
    case "$_iv" in ''|*[!0-9]*) _iv=0 ;; esac
    [ "$_iv" -gt 0 ] || return 0
    [ -n "$_ck" ] || return 0

    # The same endpoint openconnect asks for at connect, and the one f5-login
    # uses to prove a session is authorized: cheap, authenticated, and it serves
    # the logon page instead of XML once the session is gone.
    _url="${F5_SESSION_URL:-https://${VPN_SERVER}/vdesk/vpn/index.php3?outform=xml&client_version=2.0}"

    # Resolve the gateway now, while the resolver still works. Once the tunnel
    # is up vpnc-script may replace /etc/resolv.conf with the customer's DNS
    # servers, and for a split tunnel those are routinely unreachable (Riverside's
    # are) -- every poll would then fail to resolve and report a false "no
    # response from gateway". Pinning the address keeps the verdict honest.
    _host="${VPN_SERVER#*://}"; _host="${_host%%/*}"; _host="${_host%%:*}"
    # ahostsv4, not hosts: `getent hosts` returns whatever the resolver lists
    # first, which is frequently the AAAA. These tunnels are v4-only (openconnect
    # sends Protocol-Reject for IP6CP), so a v6 pin would kill every poll.
    _gwip="$(getent ahostsv4 "$_host" 2>/dev/null | awk '{print $1; exit}')"
    case "$_gwip" in *:*) _gwip="" ;; esac

    # The cookie goes in a curl config file rather than argv, where `ps` inside
    # the container would expose it.
    _hdr=/tmp/.f5-session-hdr
    (
        umask 077
        printf 'header = "Cookie: %s"\n' "$_ck" > "$_hdr"
        if [ -n "$_gwip" ]; then
            printf 'resolve = "%s:443:%s"\n' "$_host" "$_gwip" >> "$_hdr"
        fi
    )
    if [ -n "$_gwip" ]; then
        log "session keepalive: pinned $_host to $_gwip (pre-tunnel resolve)"
    else
        log "session keepalive: could not pre-resolve $_host -- polls depend on in-tunnel DNS"
    fi

    (
        while :; do
            sleep "$_iv"
            _rx=$(cat /sys/class/net/tun0/statistics/rx_bytes 2>/dev/null || echo -)
            _body=$(curl -sk --max-time 15 --config "$_hdr" "$_url" 2>/dev/null || true)
            if [ -z "$_body" ]; then
                log "session keepalive: no response from gateway (tun0 rx=$_rx)"
            elif printf '%s' "$_body" | grep -qi 'auth_form\|credentials_input\|hangup\.php3'; then
                log "session keepalive: APM SESSION EXPIRED -- gateway served the logon page (tun0 rx=$_rx)"
            else
                log "session keepalive: session ok (tun0 rx=$_rx)"
            fi
        done
    ) &
    log "session keepalive: every ${_iv}s to ${VPN_SERVER}"
}

idle() {
    # Stay in the foreground so `docker stop` and traps still work.
    while :; do
        sleep 3600 &
        wait $!
    done
}

# --- connectors -------------------------------------------------------------

connect_openconnect() {
    : "${VPN_SERVER:?VPN_SERVER is required}"
    : "${VPN_PROTOCOL:?VPN_PROTOCOL is required (anyconnect|gp|pulse|f5|fortinet|nc|array)}"

    # Scripted F5 strong-auth: openconnect ignores the SMS/EMAIL radio, so a
    # helper completes the logon by hand and we hand openconnect the resulting
    # authorized session cookie. See f5-login.sh.
    if [ "${VPN_F5_SCRIPTED:-0}" = "1" ]; then
        log "F5 scripted login -- openconnect cannot drive the strong-auth form"
        cookie="$(/usr/local/bin/f5-login)" || die "scripted F5 login failed"
        [ -n "$cookie" ] || die "scripted F5 login produced no cookie"

        set -- --protocol="$VPN_PROTOCOL" \
               --script /usr/local/bin/vpnc-wrapper \
               --os="${VPN_OS:-mac-intel}" \
               --cookie-on-stdin
        if [ -n "${VPN_SERVERCERT:-}" ]; then set -- "$@" --servercert="$VPN_SERVERCERT"; fi
        if [ -n "${VPN_EXTRA:-}" ]; then
            # shellcheck disable=SC2086
            set -- "$@" $VPN_EXTRA
        fi

        log "session obtained -- establishing tunnel"
        start_f5_session_keepalive "$cookie"
        printf '%s\n' "$cookie" | openconnect "$@" "$VPN_SERVER"
        exit $?
    fi

    set -- --protocol="$VPN_PROTOCOL" \
           --script /usr/local/bin/vpnc-wrapper \
           --os="${VPN_OS:-mac-intel}"

    if [ -n "${VPN_USER:-}" ];       then set -- "$@" --user="$VPN_USER"; fi
    if [ -n "${VPN_AUTHGROUP:-}" ];  then set -- "$@" --authgroup="$VPN_AUTHGROUP"; fi
    if [ -n "${VPN_CERT:-}" ];       then set -- "$@" -c "$VPN_CERT"; fi
    if [ -n "${VPN_KEY:-}" ];        then set -- "$@" -k "$VPN_KEY"; fi
    if [ -n "${VPN_SERVERCERT:-}" ]; then set -- "$@" --servercert="$VPN_SERVERCERT"; fi

    if [ "${VPN_COOKIE:-0}" = "1" ]; then
        set -- "$@" --cookie-on-stdin
        log "cookie mode -- paste the session cookie now, then press enter"
        log "  (F5: MRHSession=<value>, copied from devtools after the portal login)"
    fi

    # Authenticate and print the resulting session, without building a tunnel.
    # Separates "the gateway rejected me" from "the gateway authenticated me but
    # will not grant network access".
    if [ "${VPN_AUTH_ONLY:-0}" = "1" ]; then
        set -- "$@" --authenticate
        log "auth-only mode -- no tunnel will be established"
    fi

    # Deliberately unquoted: VPN_EXTRA carries additional openconnect flags.
    if [ -n "${VPN_EXTRA:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $VPN_EXTRA
    fi

    log "connecting to $VPN_SERVER via $VPN_PROTOCOL"
    exec openconnect "$@" "$VPN_SERVER"
}

connect_openfortivpn() {
    : "${VPN_SERVER:?VPN_SERVER is required}"

    set -- "$VPN_SERVER"
    if [ -n "${VPN_USER:-}" ];       then set -- "$@" --username="$VPN_USER"; fi
    if [ -n "${VPN_SERVERCERT:-}" ]; then set -- "$@" --trusted-cert="$VPN_SERVERCERT"; fi
    if [ -n "${VPN_EXTRA:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $VPN_EXTRA
    fi

    log "connecting to $VPN_SERVER via openfortivpn"
    exec openfortivpn "$@"
}

connect_openvpn() {
    conf="${VPN_CONFIG:-/config/client.ovpn}"
    [ -f "$conf" ] || die "openvpn config not found at $conf (mount it under /config)"
    log "connecting via openvpn using $conf"
    exec openvpn --config "$conf" --script-security 2
}

connect_wireguard() {
    conf="${VPN_CONFIG:-/config/wg.conf}"
    [ -f "$conf" ] || die "wireguard config not found at $conf (mount it under /config)"
    trap 'wg-quick down "$conf" >/dev/null 2>&1; exit 0' INT TERM
    wg-quick up "$conf"
    log "wireguard up"
    idle
}

# Read a secret from the terminal without echoing it.
#
# Echo goes off BEFORE the prompt is written. The credential auto-filler
# (libexec/autodetach.py) types the secret as soon as it matches the prompt in
# this output stream, so prompting first and disabling echo afterwards leaves a
# window where the pty still echoes -- and `docker run -t` sends everything the
# pty echoes to the log driver, in cleartext. stty is aimed at /dev/tty rather
# than stdin, which is not reliably the terminal here.
read_secret() {
    _prompt="$1"
    _old=""
    if [ -r /dev/tty ]; then
        _old="$(stty -g < /dev/tty 2>/dev/null || true)"
        stty -echo < /dev/tty 2>/dev/null || true
    fi
    printf '[%s] %s' "${VPN_NAME:-vpn}" "$_prompt" >&2
    IFS= read -r _val < /dev/tty
    if [ -n "$_old" ]; then
        stty "$_old" < /dev/tty 2>/dev/null || true
    else
        stty echo < /dev/tty 2>/dev/null || true
    fi
    printf '\n' >&2
    printf '%s' "$_val"
}

# FortiClient IPsec (IKEv1 aggressive + XAuth) via strongSwan. openconnect
# cannot do IPsec; this drives charon instead.
connect_strongswan() {
    : "${VPN_SERVER:?VPN_SERVER is required}"
    : "${VPN_IKE_GROUP:?VPN_IKE_GROUP (IKE local ID / group name) is required}"
    : "${VPN_USER:?VPN_USER (XAuth identity) is required}"
    conn="${VPN_NAME:-vpn}"

    # Group pre-shared key: from a gitignored secret file if the user created
    # one, otherwise prompted. Never baked into the image or the customer conf.
    psk=""
    for secret_file in "/config/secrets/${VPN_NAME}.psk" "/config/secrets/${VPN_IKE_GROUP}.psk"; do
        if [ -f "$secret_file" ]; then
            psk="$(cat "$secret_file")"
            log "using group PSK from $secret_file"
            break
        fi
    done
    [ -n "$psk" ] || psk="$(read_secret 'group pre-shared key: ')"
    [ -n "$psk" ] || die "no group PSK provided"

    # XAuth password: always prompted, never stored.
    xpw="$(read_secret "XAuth password for $VPN_USER: ")"
    [ -n "$xpw" ] || die "no XAuth password provided"

    # Aggressive mode carries a single DH group in message 1, so every IKE
    # proposal here shares modp1536 (DH5) -- what FortiClient recorded. ESP
    # proposals default to no-PFS; a customer that needs PFS appends -modp1536.
    ike="${VPN_IKE_PROPOSAL:-aes128-sha256-modp1536,aes256-sha256-modp1536,aes128-sha1-modp1536,aes256-sha1-modp1536}"
    esp="${VPN_ESP_PROPOSAL:-aes128-sha256,aes256-sha256,aes128-sha1,aes256-sha1}"

    cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=no

conn $conn
    keyexchange=ikev1
    aggressive=yes
    authby=xauthpsk
    left=%defaultroute
    leftsourceip=%config
    leftid=$VPN_IKE_GROUP
    right=$VPN_SERVER
    rightsubnet=${VPN_RIGHTSUBNET:-0.0.0.0/0}
    xauth=client
    xauth_identity=$VPN_USER
    ike=$ike
    esp=$esp
    dpdaction=${VPN_DPD:-clear}
    auto=add
EOF

    # Secrets file: wildcard PSK matches the one conn; XAuth keyed by identity.
    umask 077
    cat > /etc/ipsec.secrets <<EOF
: PSK "$psk"
$VPN_USER : XAUTH "$xpw"
EOF
    umask 022

    trap 'ipsec down "$conn" >/dev/null 2>&1; ipsec stop >/dev/null 2>&1; exit 0' INT TERM

    log "starting charon (IKEv1 aggressive + XAuth) to $VPN_SERVER as group $VPN_IKE_GROUP"
    ipsec start >/dev/null 2>&1 || die "failed to start charon"

    # Wait for the daemon's control socket before issuing 'up'.
    i=0
    while [ ! -S /run/charon.ctl ] && [ "$i" -lt 30 ]; do i=$((i + 1)); sleep 0.5; done

    if ipsec up "$conn"; then
        log "IPsec established -- $VPN_SERVER"
        ipsec statusall 2>/dev/null | grep -iE 'ESTABLISHED|INSTALLED|remote|assigned' | sed "s/^/[$conn] /" >&2 || true
    else
        die "IPsec negotiation failed -- check PSK, XAuth password, and proposals (VPN_IKE_PROPOSAL / VPN_ESP_PROPOSAL). Run 'tunnelyard logs $conn' for charon output."
    fi
    idle
}

selftest() {
    log "tun:         $([ -c /dev/net/tun ] && echo present || echo MISSING)"
    log "openconnect: $(openconnect --version 2>&1 | head -1)"
    log "strongswan:  $(ipsec --version 2>&1 | head -1)"
    log "idle -- verifying socks/forwards plumbing, ctrl-c to stop"
    idle
}

# --- main -------------------------------------------------------------------

ensure_tun
start_socks
start_forwards
start_keepalive

case "${VPN_KIND:-openconnect}" in
    openconnect)  connect_openconnect ;;
    openfortivpn) connect_openfortivpn ;;
    openvpn)      connect_openvpn ;;
    wireguard)    connect_wireguard ;;
    strongswan)   connect_strongswan ;;
    selftest)     selftest ;;
    *)            die "unknown VPN_KIND '${VPN_KIND}'" ;;
esac
