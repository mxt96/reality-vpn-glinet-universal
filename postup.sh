#!/bin/sh
# Route LAN clients through the sing-box tun — but FAIL-OPEN. table 2022 = sing-box auto_route.
# LAN subnet auto-detected (works on any GL.iNet LAN). Idempotent. Runs from cron every 2 min.
LAN=$(ip -4 route show dev br-lan scope link 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$LAN" ] && LAN=$(ip -4 -o addr show br-lan 2>/dev/null | awk 'NR==1{print $4}')
[ -z "$LAN" ] && exit 0

if ip link show singtun0 >/dev/null 2>&1 && pidof sing-box >/dev/null 2>&1; then
  # tunnel UP -> policy-route LAN through it
  ip route show table 2022 2>/dev/null | grep -q "$LAN" || ip route add "$LAN" dev br-lan table 2022 2>/dev/null
  ip rule show 2>/dev/null | grep -q "from $LAN lookup 2022" || ip rule add from "$LAN" lookup 2022 pref 500 2>/dev/null
  iptables -C FORWARD -i br-lan -o singtun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i br-lan -o singtun0 -j ACCEPT
  iptables -t nat -C POSTROUTING -o singtun0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o singtun0 -j MASQUERADE
else
  # tunnel DOWN -> if killswitch is OFF, FAIL-OPEN: drop the policy rule so LAN uses
  # the main table (normal internet). If killswitch is ON, ks-sync enforces the block.
  KS=$(uci -q get route_policy.@rule[0].killswitch)
  if [ "$KS" != "1" ]; then
    while ip rule del from "$LAN" lookup 2022 pref 500 2>/dev/null; do :; done
  fi
fi
