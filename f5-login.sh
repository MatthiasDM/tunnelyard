#!/bin/sh
# Complete an F5 BIG-IP APM strong-auth logon (username + password + an
# SMS/EMAIL one-time code) and print the resulting authorized session cookie on
# stdout as  MRHSession=<value>.
#
# This exists because openconnect's F5 form parser ignores <input type=radio>,
# so it can never submit the strong-auth method the policy requires. curl can.
# The tunnel itself is still built by openconnect, fed this cookie via --cookie.
#
# Everything except the final cookie line goes to stderr, so the caller can do
#   cookie="$(f5-login)"
# and pipe it straight into openconnect.
#
# Driven by env: VPN_SERVER, VPN_USER, VPN_F5_OTP (SMS|EMAIL, default EMAIL),
# and optionally VPN_PASSWORD (otherwise prompted, without echo).
#
# Offline test hooks:
#   f5-login parse <file>       show the parsed action + inputs of a saved page
#   f5-login buildpost <file>   show the POST args it would send (VPN_USER,
#                               VPN_PASSWORD, VPN_F5_OTP from env; code on stdin)
set -eu

log() { printf '[f5-login] %s\n' "$*" >&2; }
die() { printf '[f5-login] ERROR: %s\n' "$*" >&2; exit 1; }

# Read one secret from the terminal without echoing it.
#
# Echo is turned off BEFORE the prompt is written, and that order is the whole
# point. The credential auto-filler (libexec/autodetach.py) watches this output
# stream and types the secret the instant it matches the prompt, so the old
# prompt-then-stty order left a window in which the pty was still echoing --
# and with `docker run -t`, whatever the pty echoes is captured by the log
# driver and persisted in cleartext for the life of the container.
#
# stty is pointed at /dev/tty explicitly rather than inheriting stdin: callers
# run this inside a command substitution, so fd 1 is a pipe, and stdin is not
# guaranteed to be the terminal either.
read_secret() {
    _rs_prompt="$1"
    _rs_old=""
    if [ -r /dev/tty ]; then
        _rs_old="$(stty -g < /dev/tty 2>/dev/null || true)"
        stty -echo < /dev/tty 2>/dev/null || true
    fi
    printf '%s' "$_rs_prompt" >&2
    if [ -r /dev/tty ]; then
        IFS= read -r _rs_val < /dev/tty
    else
        IFS= read -r _rs_val
    fi
    if [ -n "$_rs_old" ]; then
        stty "$_rs_old" < /dev/tty 2>/dev/null || true
    else
        stty echo < /dev/tty 2>/dev/null || true
    fi
    printf '\n' >&2
    printf '%s' "$_rs_val"
}

# --- HTML form parsing ------------------------------------------------------

# Slice the first <form>...</form> block out of a saved page.
form_block() {
    awk '
        /<[Ff][Oo][Rr][Mm][ >]/ { inform = 1 }
        inform { print }
        /<\/[Ff][Oo][Rr][Mm]>/  { if (inform) exit }
    ' "$1"
}

# attr <tag> <name> -> value of that attribute, or empty. Quotes normalized.
attr() {
    printf '%s' "$1" | grep -oiE "$2=\"[^\"]*\"" | head -1 | sed 's/^[^=]*="//; s/"$//'
}

# Emit  type|name|value  for every <input> in the first form of <file>.
inputs() {
    form_block "$1" | tr "'" '"' | grep -oiE '<input[^>]*>' | while IFS= read -r tag; do
        t="$(attr "$tag" type)"; [ -n "$t" ] || t=text
        n="$(attr "$tag" name)"
        v="$(attr "$tag" value)"
        [ -n "$n" ] && printf '%s|%s|%s\n' "$t" "$n" "$v"
    done
}

form_action() {
    a="$(form_block "$1" | tr "'" '"' | grep -oiE '<form[^>]*>' | head -1 \
         | { grep -oiE 'action="[^"]*"' || true; } | head -1 | sed 's/^[^=]*="//; s/"$//')"
    [ -n "$a" ] && printf '%s' "$a" || printf '/my.policy'
}

# --- request building -------------------------------------------------------

VPN_USER="${VPN_USER:-}"
OTP="${VPN_F5_OTP:-EMAIL}"
PASSWORD="${VPN_PASSWORD:-}"    # a live run overwrites this via get_password

# Emit curl --data-urlencode arg pairs (one flag and one k=v per line) for the
# form in <file>: seed username/password/otp, resend hidden state tokens as-is,
# and prompt for anything else still empty -- that empty field is the one-time
# code.
build_post() {
    _file="$1"
    _otp_done=0
    inputs "$_file" | while IFS='|' read -r t n v; do
        case "$t" in
            submit|button|image) continue ;;
            radio|checkbox)
                if [ "$n" = otp ] && [ "$_otp_done" = 0 ]; then
                    _otp_done=1
                    printf ' --data-urlencode\n%s=%s\n' "$n" "$OTP"
                fi
                continue ;;
        esac
        case "$n" in
            username) printf ' --data-urlencode\n%s=%s\n' "$n" "$VPN_USER" ;;
            password) printf ' --data-urlencode\n%s=%s\n' "$n" "$PASSWORD" ;;
            otp)      if [ "$_otp_done" = 0 ]; then _otp_done=1; printf ' --data-urlencode\n%s=%s\n' "$n" "$OTP"; fi ;;
            *)
                if [ -n "$v" ]; then
                    printf ' --data-urlencode\n%s=%s\n' "$n" "$v"
                else
                    # This while loop is fed by a pipe, so its stdin is the
                    # inputs stream, not the user. Read the code from the
                    # terminal directly. VPN_TEST_CODE bypasses the tty offline.
                    if [ -n "${VPN_TEST_CODE:-}" ]; then
                        code="$VPN_TEST_CODE"
                    else
                        code="$(read_secret "$(printf '[f5-login] enter value for \"%s\" (check your %s): ' "$n" "$OTP")")"
                    fi
                    printf ' --data-urlencode\n%s=%s\n' "$n" "$code"
                fi ;;
        esac
    done
}

# --- offline test hooks -----------------------------------------------------

case "${1:-}" in
    parse)
        [ -n "${2:-}" ] || die "usage: f5-login parse <file>"
        printf 'action: %s\n' "$(form_action "$2")"
        printf 'inputs:\n'
        inputs "$2" | sed 's/^/  /'
        exit 0 ;;
    buildpost)
        [ -n "${2:-}" ] || die "usage: f5-login buildpost <file>"
        build_post "$2"
        exit 0 ;;
esac

# --- live login -------------------------------------------------------------

: "${VPN_SERVER:?VPN_SERVER required}"
: "${VPN_USER:?VPN_USER required}"
BASE="https://$VPN_SERVER"
JAR="$(mktemp)"
PAGE="$(mktemp)"
trap 'rm -f "$JAR" "$PAGE"' EXIT
CURL="curl -skL --max-time 40 -c $JAR -b $JAR"

get_password() {
    if [ -n "${VPN_PASSWORD:-}" ]; then printf '%s' "$VPN_PASSWORD"; return; fi
    read_secret "$(printf '[f5-login] password for %s: ' "$VPN_USER")"
}

post_form() {
    _file="$1"; _action="$2"
    _args="$(mktemp)"
    build_post "$_file" > "$_args"
    _url="$_action"
    case "$_url" in http*) : ;; /*) _url="$BASE$_url" ;; *) _url="$BASE/$_url" ;; esac
    # shellcheck disable=SC2046
    $CURL $(cat "$_args") -o "$PAGE" "$_url"
    rm -f "$_args"
}

extract_cookie() {
    awk '$6=="MRHSession"      {mrh=$7}
         $6=="LastMRH_Session" {last=$7}
         END{ if(mrh!=""){ printf "MRHSession=%s", mrh; if(last!="") printf ";LastMRH_Session=%s", last; print "" } }' "$JAR"
}

PASSWORD="$(get_password)"

log "fetching logon page from $BASE"
$CURL -o "$PAGE" "$BASE/" || die "could not reach $BASE"
grep -qi '<form' "$PAGE" || die "no logon form at $BASE (already authenticated? wrong host?)"

round=0
while [ "$round" -lt 4 ]; do
    round=$((round + 1))
    action="$(form_action "$PAGE")"
    log "submitting form (round $round), otp=$OTP"
    post_form "$PAGE" "$action"

    if grep -qi 'hangup\.php3\|logon denied\|access was denied\|erreur' "$PAGE"; then
        die "policy denied the logon (round $round) -- wrong strong-auth method, credentials, or code"
    fi
    if ! grep -qi '<form' "$PAGE"; then
        log "no further form -- logon appears complete"
        break
    fi
    if [ "$round" -gt 1 ] && grep -qi 'name="password"' "$PAGE"; then
        die "returned to the password form -- credentials or code rejected"
    fi
done

# An MRHSession exists even before authentication, so its presence proves
# nothing. Make openconnect's own first request and confirm we are not bounced
# back to the logon page -- that is the real test of an authorized session.
log "verifying the session is authorized for network access"
VERIFY="$(mktemp)"
$CURL -o "$VERIFY" "$BASE/vdesk/vpn/index.php3?outform=xml&client_version=2.0" || true
if grep -qi 'auth_form\|credentials_input\|hangup\.php3' "$VERIFY"; then
    rm -f "$VERIFY"
    die "session not authorized -- the gateway bounced back to the logon page. Strong-auth failed, or Endpoint Inspection is required for this policy (see the fallback in customers/riverside.conf)."
fi
rm -f "$VERIFY"

cookie="$(extract_cookie)"
[ -n "$cookie" ] || die "no MRHSession in jar -- logon did not complete"
log "session authorized -- handing off to openconnect"
printf '%s\n' "$cookie"
