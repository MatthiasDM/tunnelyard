# Configuration guide

Everything the tool does is driven by **one file per customer**:
`customers/<name>.conf`. This guide explains every setting and gives a
copy‑paste example for each kind of VPN, plus the extras (RDP, SSH, custom
commands, 1Password).

- [How a customer config works](#how-a-customer-config-works)
- [Quick start](#quick-start)
- [Settings reference](#settings-reference)
- [Examples by gateway type](#examples-by-gateway-type)
  - [Cisco AnyConnect](#cisco-anyconnect)
  - [Palo Alto GlobalProtect](#palo-alto-globalprotect)
  - [Ivanti / Pulse](#ivanti--pulse)
  - [FortiGate SSL VPN](#fortigate-ssl-vpn)
  - [F5 BIG-IP APM](#f5-big-ip-apm)
  - [IPsec (FortiClient / strongSwan)](#ipsec-forticlient--strongswan)
  - [OpenVPN](#openvpn)
  - [WireGuard](#wireguard)
- [Reaching customer hosts](#reaching-customer-hosts)
  - [SOCKS proxy](#socks-proxy)
  - [Port forwards](#port-forwards)
  - [SSH shortcuts](#ssh-shortcuts)
  - [Custom commands](#custom-commands)
  - [RDP in a browser](#rdp-in-a-browser)
- [Credentials from 1Password](#credentials-from-1password)
- [Sharing your configs](#sharing-your-configs)
- [Picking the image (openconnect version)](#picking-the-image-openconnect-version)
- [Troubleshooting](#troubleshooting)

---

## How a customer config works

- **One file per customer:** `customers/<name>.conf`. The `<name>` is what you
  type: `tunnelyard up <name>`, and it names the container `vpn-<name>`.
- **Format:** plain `KEY=value`, one per line. **No quotes**, **no `$expansion`**,
  and **no trailing comments on a value line** — the file is read both by
  `docker --env-file` and by a small parser, so keep values bare.

  ```conf
  VPN_USER=jdoe            # good
  VPN_USER="jdoe"          # WRONG: the quotes become part of the value
  VPN_USER=jdoe  # my acct # WRONG: the comment becomes part of the value
  ```
- **Create one** by copying the template:

  ```bash
  cp customers/_template.conf customers/acme.conf
  tunnelyard edit acme            # opens it in $EDITOR (or edit the file directly)
  ```
- **Passwords are never stored here.** You either type them at connect, or pull
  them from 1Password (see [below](#credentials-from-1password)).
- **Configs are gitignored.** `customers/*.conf` stays on your machine; only
  `customers/_template.conf` is committed. Same for `ssh/config`, PSKs and VPN
  profiles.
- **List what you have:** `tunnelyard list`.
- **Somewhere else, if you want:** `VPN_CUSTOMERS` overrides the directory, so
  you can keep a second set (a demo, a colleague's export) without disturbing
  your own. `docs/demo-customers/` ships an invented set:

  ```bash
  VPN_CUSTOMERS=docs/demo-customers tunnelyard tui
  ```

---

## Quick start

The smallest possible working config — a username/password gateway:

```conf
# customers/acme.conf
SOCKS_PORT=1101
VPN_KIND=openconnect
VPN_PROTOCOL=anyconnect
VPN_SERVER=vpn.acme.example.com
VPN_USER=jdoe
```

```bash
tunnelyard up acme          # prompts for the password, connects
tunnelyard status           # confirm it's up
curl --socks5-hostname 127.0.0.1:1101 https://intranet.acme.example.com
tunnelyard down acme
```

Every customer needs at least a **unique `SOCKS_PORT`**, a **`VPN_KIND`**, and
enough for that kind to connect (usually `VPN_SERVER`). Pick any free port in
the 1100+ range; `tunnelyard list` shows what's already taken.

---

## Settings reference

### Core

| Key | Required | Meaning |
|---|---|---|
| `SOCKS_PORT` | yes | Host port for this customer's SOCKS5 proxy (`127.0.0.1:<port>`). Must be unique per customer. |
| `VPN_KIND` | yes | Client to use: `openconnect`, `openfortivpn`, `openvpn`, `wireguard`, or `strongswan`. |
| `VPN_PROTOCOL` | openconnect only | `anyconnect`, `gp`, `pulse`, `f5`, `fortinet`, `nc`, or `array`. |
| `VPN_SERVER` | most | Gateway host, `host:port`, or `https://host/path`. |
| `VPN_USER` | usually | Login username. Left blank ⇒ the client prompts (or 1Password fills it). |

### Auth & protocol tuning (openconnect)

| Key | Meaning |
|---|---|
| `VPN_AUTHGROUP` | Tunnel group / realm, if the gateway shows a menu. |
| `VPN_OS` | OS reported to the gateway: `mac-intel`, `linux-64`, `win`, … Some policies gate on it. |
| `VPN_COOKIE` | `1` = authenticate with a session cookie pasted on stdin instead of user/pass (see [F5](#f5-big-ip-apm)). |
| `VPN_CERT` / `VPN_KEY` | Client-certificate auth. Put the files under `./config` (mounted at `/config`). |
| `VPN_SERVERCERT` | Pin the gateway cert, e.g. `pin-sha256:…`. openconnect prints the value to use on first connect. |
| `VPN_EXTRA` | Extra flags passed verbatim to the client (word-split, no quoting). e.g. `--no-dtls`, `--csd-wrapper=…`. |

### F5 scripted login

| Key | Meaning |
|---|---|
| `VPN_F5_SCRIPTED` | `1` = drive the F5 logon form by hand (needed when openconnect can't post the SMS/EMAIL radio). |
| `VPN_F5_OTP` | `SMS` or `EMAIL` — which channel the one-time code is sent to. |

### IPsec (strongSwan)

| Key | Meaning |
|---|---|
| `VPN_IKE_GROUP` | IKE local ID / group name (aggressive mode). |
| `VPN_IKE_PROPOSAL` | Phase‑1 proposals, e.g. `aes256-sha256-modp1536`. |
| `VPN_ESP_PROPOSAL` | Phase‑2 proposals, e.g. `aes256-sha256`. |
| `VPN_DPD` | Dead‑peer‑detection action (`clear`, `restart`, `none`). |
| PSK | **Not** in the config — a gitignored `config/secrets/<name>.psk` file, or prompted. |

### openvpn / wireguard

| Key | Meaning |
|---|---|
| `VPN_CONFIG` | Path (inside the container) to the profile, e.g. `/config/client.ovpn` or `/config/wg.conf`. Put the file under `./config`. |

### Routing / DNS

| Key | Meaning |
|---|---|
| `VPN_ROUTE_DNS` | `1` = route the gateway's DNS servers over the tunnel (for split tunnels that hand out unreachable resolvers). Default `0`. |

### Reaching hosts

| Key | Meaning |
|---|---|
| `FORWARDS` | Comma-separated `lport:remotehost:rport`. Each `lport` is published on `127.0.0.1`. |
| `RDP_SERVER` / `RDP_USER` | Default target + user for `tunnelyard rdp <customer>` and the TUI's `^t`. |
| `RDP_GEOMETRY` | Desktop size for RDP, e.g. `1600x900`. |
| `CMD_<label>` | A custom command runnable from the TUI (`^n`) or `tunnelyard run <customer> <label>`, executed **inside** the tunnel. |

### Health & keepalive

A running container is not a working tunnel: when a gateway expires the session
server-side, the client keeps its transport up and silently drops everything
sent into it. `tunnelyard status`, `tunnelyard health` and the TUI therefore probe the data
path — a TCP connection through the tunnel, plus the interface's receive counter
— instead of trusting the container's own state. A refused connection counts as
healthy; the RST proves return traffic. See "up means the tunnel carries
traffic" in the README.

| Key | Meaning |
|---|---|
| `HEALTH_PROBE` | `host:port` the health check connects to. Defaults to the first `FORWARDS` entry, so most customers need nothing here. Without either, state is reported as `up (unverified)` rather than `up`. |
| `KEEPALIVE_INTERVAL` | Seconds between keepalive pokes through the tunnel; `0` (default) disables. Set it comfortably under the gateway's idle timeout, which the tunnel logs at connect (`Idle timeout is N minutes`). Gateways measure user traffic, so the client's own protocol keepalives do not prevent expiry. |
| `KEEPALIVE_TARGET` | `host:port` for those pokes. Defaults to the `HEALTH_PROBE` / `FORWARDS` target. |
| `F5_SESSION_KEEPALIVE` | F5 scripted-login only. Seconds between HTTPS polls of the gateway carrying the APM session cookie; `0` disables. Some F5 policies expire the APM session on **HTTP** inactivity and ignore tunnel traffic entirely — for those, `KEEPALIVE_INTERVAL` cannot help and this is what keeps the session alive. |
| `F5_SESSION_URL` | Override the polled URL. Defaults to the `vdesk/vpn/index.php3` query openconnect itself makes at connect. |

`KEEPALIVE_INTERVAL` is off by default and opted into per customer: an
always-alive session may be at odds with the customer's own security policy.

### Diagnosing a stale tunnel

`tunnelyard health` tells you *that* a tunnel is dead. Attributing it takes one more
step, because two very different failures look identical from the host: the
gateway expired the **APM session** underneath a working transport, or the
**transport** broke while the session was still fine.

`F5_SESSION_KEEPALIVE` settles it. Every poll writes one line to the tunnel log
carrying both facts — whether the gateway still honours the session cookie, and
the tunnel interface's receive counter at that moment:

```
[riverside] session keepalive: session ok (tun0 rx=42443)
[riverside] session keepalive: APM SESSION EXPIRED -- gateway served the logon page (tun0 rx=42443)
```

Read the run with `tunnelyard logs riverside | grep "session keepalive"` once it goes
stale, and match it against this:

| what the log shows | what it means | what to do |
|---|---|---|
| `APM SESSION EXPIRED` | The APM session was reaped despite the HTTP refresh, so the polled URL does not count as activity for this policy. | Point `F5_SESSION_URL` at a real protected resource rather than a status endpoint. |
| `session ok`, and `rx` stops moving | The session outlived the data path — this is a transport failure, not a timeout. | Try `VPN_EXTRA=--no-dtls`. openconnect logs `SSL disconnected and DTLS established` at connect; if the gateway meters the TLS channel, moving traffic back onto it is the fix. |
| `session ok`, `rx` still climbing | The tunnel is fine and the health probe's target is what died. | Repoint `HEALTH_PROBE` at a more reliable host. |
| `no response from gateway` | The poll itself could not reach the gateway. | Check the `pinned <host> to <ip>` line at connect; without it the poll depends on in-tunnel DNS, which a split tunnel usually breaks. |

### Image & status

| Key | Meaning |
|---|---|
| `VPN_IMAGE` | Pin a specific image, e.g. `vpn-base-next:latest` for a newer openconnect. See [below](#picking-the-image-openconnect-version). |
| `VPN_STATUS` | `pending` = documented but not runnable yet; `tunnelyard up` refuses it. |

### 1Password

| Key | Meaning |
|---|---|
| `OP_ITEM` | 1Password item to pull credentials from (name, UUID, or `op://vault/item`). |
| `OP_OTP` | `1` = also auto-fill the item's current TOTP at the 2FA prompt. |

---

## Examples by gateway type

Each block is a complete `customers/<name>.conf`. Change the port, host and
username to yours.

### Cisco AnyConnect

```conf
SOCKS_PORT=1102
VPN_KIND=openconnect
VPN_PROTOCOL=anyconnect
VPN_SERVER=vpn.customer.example.com
VPN_USER=jdoe
# VPN_AUTHGROUP=Employees      # if the gateway shows a group dropdown
```

> If it authenticates then drops the tunnel, the gateway likely enforces **ISE
> posture** — openconnect can't satisfy that; that customer needs a VM.

### Palo Alto GlobalProtect

```conf
SOCKS_PORT=1103
VPN_KIND=openconnect
VPN_PROTOCOL=gp
VPN_IMAGE=vpn-base-next:latest          # 9.10+ needed for challenge-based 2FA
VPN_SERVER=gp.customer.example.com
VPN_USER=DOMAIN\jdoe                     # AD domain-qualified is fine
VPN_EXTRA=--csd-wrapper=/usr/libexec/openconnect/hipreport.sh   # if HIP is required
```

> **2FA:** challenge-based tokens need openconnect ≥ 9.10, so pin
> `vpn-base-next` (build it once — see [image selection](#picking-the-image-openconnect-version)).
> **HIP:** if the portal enforces posture, the `--csd-wrapper` submits a
> generated HIP report; some gateways accept it, strict ones don't (then: VM).

### Ivanti / Pulse

```conf
SOCKS_PORT=1104
VPN_KIND=openconnect
VPN_PROTOCOL=pulse
VPN_IMAGE=vpn-base-next:latest          # 9.21+ needed by some Ivanti gateways
VPN_SERVER=access.customer.example.com/realmpath
VPN_USER=jdoe
```

> Some Ivanti gateways reject older openconnect at the handshake
> (`clientCapabilities … not present`). openconnect **9.21** fixes it, so pin
> the newer image. A `/path` after the host is the connection's realm — keep it.

### FortiGate SSL VPN

```conf
SOCKS_PORT=1105
VPN_KIND=openconnect
VPN_PROTOCOL=fortinet
VPN_SERVER=vpn.customer.example.com:10443    # custom port is common
VPN_USER=jdoe
# VPN_SERVERCERT=pin-sha256:xxxx              # openconnect prints this on first connect
```

> FortiGate 2FA is a token prompt — enter it when asked. `openconnect` is the
> default and usually best; `openfortivpn` exists too but needs kernel PPP, which
> a container doesn't have, so **stick with `VPN_KIND=openconnect`** here.

### F5 BIG-IP APM

Simple user/password portal:

```conf
SOCKS_PORT=1106
VPN_KIND=openconnect
VPN_PROTOCOL=f5
VPN_SERVER=webaccess.customer.example.com
VPN_USER=jdoe
```

Portal with an SMS/EMAIL one-time code that openconnect can't post (scripted
login drives the form itself, then prompts for the emailed/texted code):

```conf
SOCKS_PORT=1106
VPN_KIND=openconnect
VPN_PROTOCOL=f5
VPN_SERVER=webaccess.customer.example.com
VPN_USER=jdoe
VPN_F5_SCRIPTED=1
VPN_F5_OTP=EMAIL           # or SMS
```

> If even the scripted login is refused after the code, the policy requires
> Endpoint Inspection. Fallback: log in via the browser, then set `VPN_COOKIE=1`
> and paste the `MRHSession` cookie at connect.

### IPsec (FortiClient / strongSwan)

For IKEv1 aggressive + XAuth (what FortiClient calls an IPsec tunnel).
openconnect can't do IPsec, so `VPN_KIND=strongswan`:

```conf
SOCKS_PORT=1107
VPN_KIND=strongswan
VPN_SERVER=ipsec.customer.example.com
VPN_IKE_GROUP=mygroup                 # the IKE local ID / group name
VPN_USER=jdoe                         # XAuth username
VPN_IKE_PROPOSAL=aes256-sha256-modp1536
VPN_ESP_PROPOSAL=aes256-sha256
VPN_DPD=clear
```

The **pre-shared key** is never in the config. Provide it either as a gitignored
file or let the container prompt:

```bash
mkdir -p config/secrets
printf '%s' 'THE-GROUP-PSK' > config/secrets/acme.psk   # or <group>.psk
```

Your XAuth password is always prompted (or from 1Password).

### OpenVPN

```conf
SOCKS_PORT=1108
VPN_KIND=openvpn
VPN_CONFIG=/config/acme.ovpn
```

```bash
# put the profile (and any certs it references) where the container can read it:
mkdir -p config
cp ~/Downloads/acme.ovpn config/acme.ovpn
```

`./config` is mounted read-only at `/config` inside the container.

### WireGuard

```conf
SOCKS_PORT=1109
VPN_KIND=wireguard
VPN_CONFIG=/config/acme-wg.conf
```

```bash
cp ~/Downloads/acme.conf config/acme-wg.conf
```

> Drop any `DNS =` line that points at a resolver you can't reach, and keep
> `AllowedIPs` scoped to the customer's subnets.

---

## Reaching customer hosts

Once a tunnel is up, its routes and DNS live **inside** its container. You reach
them through doors you open on `127.0.0.1`.

### SOCKS proxy

Every customer has one, on its `SOCKS_PORT`:

```bash
curl --socks5-hostname 127.0.0.1:1101 https://intranet.customer.local
```

Use `--socks5-hostname` (not `--socks5`) so **DNS resolves inside the tunnel** —
the only way internal names work. In Firefox: SOCKS v5 + "Proxy DNS when using
SOCKS v5". One browser profile per customer is tidy.

### Port forwards

For a fixed endpoint (MLLP, SFTP, a database), skip SOCKS and forward the port:

```conf
FORWARDS=2575:10.20.5.40:2575,2222:10.20.5.41:22
```

Format is `localport:remotehost:remoteport`, comma-separated. Each `localport`
is published on `127.0.0.1`, so `localhost:2575` behaves like the customer host.

> **Left-hand port must be free on your Mac.** If something already uses it
> (e.g. a local app on 2575), pick another: `12575:10.20.5.40:2575` → reach it at
> `localhost:12575`. `tunnelyard up` preflights these and tells you which port clashes.

### SSH shortcuts

Keep SSH targets in the repo, not your global `~/.ssh/config`:

```bash
cp ssh/config.example ssh/config      # gitignored; holds internal IPs/users
```

```conf
# ssh/config
Host acme-app
    HostName 10.20.5.40
    User jdoe
    ProxyCommand ncat --proxy 127.0.0.1:1101 --proxy-type socks5 %h %p
```

The `ProxyCommand` port is that customer's `SOCKS_PORT`. Then:

```bash
tunnelyard up acme
tunnelyard ssh acme-app         # ssh through the tunnel's proxy
tunnelyard ssh                  # with no args: lists defined hosts
```

In the TUI, `^s` finds the host(s) whose proxy port matches the highlighted
customer and connects. Options like forcing password auth go in the block:

```conf
Host acme-jump
    HostName 10.20.5.40
    User svc
    IdentitiesOnly yes
    PubkeyAuthentication no
    ProxyCommand ncat --proxy 127.0.0.1:1101 --proxy-type socks5 %h %p
```

### Custom commands

Save arbitrary commands per customer; they run **inside** the tunnel container,
so a plain `ssh user@10.x.x.x` reaches the internal host with no proxy:

```conf
CMD_app=ssh -o StrictHostKeyChecking=accept-new svc@10.20.5.40
CMD_db=ssh -o StrictHostKeyChecking=accept-new dba@10.20.5.41
```

```bash
tunnelyard run acme app         # runs CMD_app inside vpn-acme
tunnelyard run acme             # lists the labels
```

In the TUI: `^n` shows the list (plus "add new" to define one on the spot).

**Running on the Mac instead.** A container has no desktop, so anything
graphical — opening a URL in a browser, say — cannot run inside it. Prefix the
command with `@host ` and it runs on your Mac. The tunnel still has to be up,
because such a command invariably goes through its proxy:

```conf
CMD_console=@host "$ROOT"/libexec/open-manager acme 1081 https://console.acme.internal
```

`libexec/open-manager <customer> <socks-port> <url>` is the helper for exactly
that case: it opens Firefox on a dedicated profile under `browser-profiles/`,
pinned to that tunnel's SOCKS port **with remote DNS**. Remote DNS is the point —
internal hostnames usually have no public record, so the name has to be resolved
by the customer's resolvers inside the tunnel. A per-customer profile also means
that window cannot reach anything except through that tunnel, and your normal
browser is left alone.

`"$ROOT"` expands to the repo root, so the entry survives the repo moving.

### RDP in a browser

Remote-desktop to a Windows host with **no local RDP client** — it renders into
a browser tab through the tunnel's SOCKS proxy. Set the target once:

```conf
RDP_SERVER=10.20.0.9
RDP_USER=DOMAIN\jdoe
# RDP_GEOMETRY=1600x900
```

```bash
tunnelyard up acme
tunnelyard rdp acme             # prompts only for the password, opens the browser
```

Or from the TUI: `^t`. The web port is `SOCKS_PORT + 5000` (e.g. 1101 → 6101).
`tunnelyard rdp-stop acme` ends it; `tunnelyard down acme` stops it with the tunnel.

> A wrong password is retried **once** then stopped, to avoid an AD lockout
> (`RDP_AUTH_RETRIES=0` to never retry). Prefer the server's **IP** for the
> target — proxy-side name resolution is flaky.

---

## Credentials from 1Password

Connect without typing anything, pulling username / password / TOTP from
1Password at connect time.

**One-time setup:** in the 1Password desktop app, **Settings → Developer →
"Integrate with 1Password CLI"** (lets `op` use your accounts with Touch ID).

Then point a customer at its item:

```conf
OP_ITEM=op://Private/Acme VPN
OP_OTP=1                  # also auto-fill the current TOTP at the 2FA prompt
```

On `tunnelyard up acme`, `op` runs on your Mac (Touch ID) and the values are typed
straight into the client:

- the item's **username** fills `VPN_USER` when that's blank;
- the **password** is typed at the password prompt;
- with `OP_OTP=1`, the **one-time password** is typed at the 2FA prompt.

Secrets go from `op` into the VPN client and **never** enter the container's
environment or `docker inspect`. If a gateway's 2FA prompt isn't recognised, set
`VPN_OP_TOKEN_RE` to a regex that matches it.

> Covers openconnect-based customers (GlobalProtect, Pulse/Ivanti, FortiGate SSL,
> AnyConnect, F5). The F5 **scripted** login and SMS/email codes still prompt.

---

## Sharing your configs

A config carries no passwords, but it does carry your account at the customer
(`VPN_USER`, `RDP_USER`) and a pointer into your own 1Password vault
(`OP_ITEM`) — all per-person. It also carries gateway hostnames and internal
addresses, which is why `customers/*.conf` is gitignored and should stay that
way.

To hand the useful part to a colleague:

```bash
./libexec/export-configs ~/Downloads/vpn-configs.tar.gz
```

That strips those three fields — wherever they appear, including inside
comments, not merely on their own lines — and verifies the finished tarball,
exiting non-zero if anything survived. What is kept is the part worth sharing:
gateway hostnames, protocols, ports, forwards, health probes, `CMD_` entries and
every comment explaining a gateway's quirks. The recipient drops the files into
their own `customers/` and fills in their own three fields.

The result still lists customer gateways and internal IPs, so put it in
1Password or an equivalent access-controlled store — not in git.

---

## Picking the image (openconnect version)

Most customers run on the default `vpn-base` image (openconnect 9.01). A few
gateways need newer openconnect:

| Need | Image | openconnect |
|---|---|---|
| default | `vpn-base` | 9.01 |
| GlobalProtect challenge 2FA | `vpn-base-next` (trixie) | 9.12 |
| Ivanti `clientCapabilities` | `vpn-base-next` (sid) | 9.21 |

Build the newer image once, then pin it per customer with
`VPN_IMAGE=vpn-base-next:latest`:

```bash
# 9.21 (covers both GlobalProtect 2FA and Ivanti):
docker build --build-arg BASE=debian:sid -t vpn-base-next:latest .
```

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `host port N … already in use` | A `FORWARDS` left-hand port (or `SOCKS_PORT`) clashes with a local app. Change it in the config. |
| Authenticates, then no tunnel | Endpoint posture enforced (ISE / HIP / Host Checker / F5 inspection). openconnect can't satisfy it — that customer needs the real client in a VM. |
| Internal names don't resolve | You used `--socks5` instead of `--socks5-hostname`, or the browser's "Proxy DNS" toggle is off. |
| `clientCapabilities … not present` (Ivanti) | Pin `VPN_IMAGE=vpn-base-next:latest` (openconnect 9.21). |
| GlobalProtect "Failed to parse server response" | Challenge 2FA on old openconnect — pin the newer image. |
| No traffic though the tunnel is "up" | Split tunnel with ESP not established, or posture gating. For Pulse/GP try `VPN_EXTRA=--no-dtls`. |
| `tunnelyard run` says "not found" | The container predates a tool added to the image — `tunnelyard restart <customer>` to recreate it. |
| Tunnel drops after minutes idle | Gateway idle timeout — keep traffic flowing (e.g. `ServerAliveInterval` for SSH). |

See the top-level [README](../README.md) for the command reference and the TUI.
