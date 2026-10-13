#!/bin/sh
# Wraps the stock vpnc-script so we can fix up routing after it runs.
#
# Gateways routinely hand out DNS servers that sit outside the split-tunnel
# include list, which leaves resolv.conf pointing at unroutable addresses and
# every lookup timing out. VPN_ROUTE_DNS=1 pushes a host route for each
# nameserver over the tunnel. Off by default: on a strict policy the gateway
# will drop that traffic anyway, and a silent extra route is worse than none.
/usr/share/vpnc-scripts/vpnc-script "$@"
rc=$?

if [ "${VPN_ROUTE_DNS:-0}" = "1" ] && [ "${reason:-}" = "connect" ]; then
    for ns in ${INTERNAL_IP4_DNS:-}; do
        if ip route replace "$ns" dev "$TUNDEV" 2>/dev/null; then
            printf '[%s] routed DNS %s via %s\n' "${VPN_NAME:-vpn}" "$ns" "$TUNDEV" >&2
        else
            printf '[%s] could not route DNS %s via %s\n' "${VPN_NAME:-vpn}" "$ns" "$TUNDEV" >&2
        fi
    done
fi

exit $rc
