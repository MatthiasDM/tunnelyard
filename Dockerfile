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
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint
COPY vpnc-wrapper.sh /usr/local/bin/vpnc-wrapper
COPY f5-login.sh /usr/local/bin/f5-login
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/vpnc-wrapper /usr/local/bin/f5-login

ENTRYPOINT ["/usr/local/bin/entrypoint"]
