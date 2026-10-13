#!/bin/sh
# Render a remote RDP desktop into a browser (noVNC), reaching the host through
# a SOCKS5 proxy (the customer tunnel). The chain is:
#
#   Xvfb (headless X)  <-  xfreerdp (draws the remote desktop into Xvfb)
#        |                      \__ /proxy:socks5://<tunnel socks> /v:<server>
#   x11vnc (exports Xvfb over VNC)  ->  websockify + noVNC  ->  browser
#
# Env: RDP_SERVER (required), RDP_SOCKS (host:port, required), RDP_WEB (web port),
#      RDP_GEOMETRY, RDP_USER, RDP_DOMAIN, RDP_PASS.
set -eu

: "${RDP_SERVER:?RDP_SERVER required}"
: "${RDP_SOCKS:?RDP_SOCKS (host:port of the tunnel SOCKS proxy) required}"
WEB="${RDP_WEB:-6080}"
GEO="${RDP_GEOMETRY:-1440x900}"
RDP_PASS="${RDP_PASS:-}"
DPY=":0"

log() { printf '[rdp] %s\n' "$*" >&2; }

# Headless X server.
Xvfb "$DPY" -screen 0 "${GEO}x24" -nolisten tcp >/tmp/xvfb.log 2>&1 &
export DISPLAY="$DPY"
i=0
while ! xdpyinfo >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 40 ] && { log "Xvfb did not start"; cat /tmp/xvfb.log >&2; exit 1; }
    sleep 0.25
done

# Export the display over VNC (localhost only; reached solely via the web port).
x11vnc -display "$DPY" -forever -shared -nopw -quiet -localhost -rfbport 5900 \
    >/tmp/x11vnc.log 2>&1 &

# Serve the noVNC web client + websocket bridge to the VNC port.
websockify --web /usr/share/novnc "$WEB" localhost:5900 >/tmp/ws.log 2>&1 &

log "web client ready on :$WEB -- connecting to $RDP_SERVER via socks5 $RDP_SOCKS"

set -- /v:"$RDP_SERVER" \
       /proxy:socks5://"$RDP_SOCKS" \
       /size:"$GEO" \
       /cert:ignore \
       +clipboard \
       -grab-keyboard \
       /log-level:INFO
[ -n "${RDP_USER:-}" ]   && set -- "$@" /u:"$RDP_USER"
[ -n "${RDP_DOMAIN:-}" ] && set -- "$@" /d:"$RDP_DOMAIN"
[ -n "$RDP_PASS" ]       && set -- "$@" /p:"$RDP_PASS"

# Reconnect loop -- but never hammer credentials: the password is fixed (from
# env), so a wrong one re-submitted in a tight loop would trip the account
# lockout. Fast/auth failures are capped at RDP_AUTH_RETRIES (default 1). A
# session that actually ran (>= RDP_MIN_SESSION_SECS) resets the counter, so a
# genuine mid-session tunnel drop still auto-reconnects.
fails=0
max_retries=${RDP_AUTH_RETRIES:-1}
min_session=${RDP_MIN_SESSION_SECS:-20}
while :; do
    start=$(date +%s 2>/dev/null || echo 0)
    xfreerdp "$@" >/tmp/rdp.log 2>&1 || true
    end=$(date +%s 2>/dev/null || echo 0)
    dur=$((end - start))
    tail -n 25 /tmp/rdp.log >&2

    authfail=0
    if grep -qiE 'AUTHENTICATION_FAILED|LOGON_FAILURE|check your credentials|account.*(lock|disabled)|password.*(expired|incorrect)|ERRCONNECT_AUTH' /tmp/rdp.log; then
        authfail=1
    fi

    # A real session ran and only then dropped -> credentials are good, reconnect.
    if [ "$authfail" -eq 0 ] && [ "$dur" -ge "$min_session" ]; then
        fails=0
        log "session ended after ${dur}s -- reconnecting in 5s ('vpn rdp-stop' to end)"
        sleep 5
        continue
    fi

    fails=$((fails + 1))
    [ "$authfail" -eq 1 ] \
        && log "authentication failed (attempt $fails/$((max_retries + 1)))" \
        || log "connection failed after ${dur}s (attempt $fails/$((max_retries + 1)))"

    if [ "$fails" -gt "$max_retries" ]; then
        log "stopping after $fails attempts to avoid an account lockout."
        log "check the password, then run 'vpn rdp <customer>' again."
        break
    fi
    log "retrying once in 5s..."
    sleep 5
done
