# Base is overridable so a newer image can be built for customers that need
# openconnect fixes not in bookworm's 9.01 -- e.g. a GlobalProtect gateway's
# challenge-based 2FA (>=9.10) or an Ivanti gateway's clientCapabilities (>=9.21):
#   docker build --build-arg BASE=debian:sid -t vpn-base-next:latest .   # 9.21
#   docker build --build-arg BASE=debian:trixie-slim -t vpn-base-next:latest .  # 9.12
ARG BASE=debian:bookworm-slim
FROM ${BASE}

# One image for every customer. The per-customer difference lives entirely in
# customers/<name>.conf, so there is only ever one image to rebuild.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openconnect \
      vpnc-scripts \
      openfortivpn \
      openvpn \
      wireguard-tools \
      openresolv \
      strongswan \
      strongswan-starter \
      libcharon-extra-plugins \
      libcharon-extauth-plugins \
      microsocks \
      openssh-client \
      socat \
      iproute2 \
      iputils-ping \
      dnsutils \
      curl \
      ca-certificates \
      python3 \
      python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Check Point: cpyvpn, a pure-Python client for the TRAC / SSL Network Extender
# protocol (GPLv3). Pinned, in its own venv so it never touches the system
# python. The connector runs it through checkpoint-client, which repairs its
# vpnc-script mode and adds the probe / auth-only modes -- see that file.
RUN python3 -m venv /opt/cpyvpn \
 && /opt/cpyvpn/bin/pip install --no-cache-dir cpyvpn==1.6.4

COPY entrypoint.sh /usr/local/bin/entrypoint
COPY vpnc-wrapper.sh /usr/local/bin/vpnc-wrapper
COPY f5-login.sh /usr/local/bin/f5-login
COPY checkpoint-client.py /usr/local/bin/checkpoint-client
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/vpnc-wrapper /usr/local/bin/f5-login \
             /usr/local/bin/checkpoint-client

ENTRYPOINT ["/usr/local/bin/entrypoint"]
