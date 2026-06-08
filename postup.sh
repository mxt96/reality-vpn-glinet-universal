#!/bin/sh
# Route LAN clients through the sing-box tun — but FAIL-OPEN. table 2022 = sing-box auto_route.
# LAN subnet auto-detected (works on any GL.iNet LAN). Idempotent. Runs from cron every 2 min.
LAN=$(ip -4 route show dev br-lan scope link 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$LAN" ] && LAN=$(ip -4 -o addr show br-lan 2>/dev/null | awk 'NR==1{print $4}')
[ -z "$LAN" ] && exit 0

# tunnel HEALTH, not just liveness: a live sing-box with singtun0 up can still carry no
# traffic (server down / handshake lost / VPS restart). Routing the LAN into a dead tunnel
# is what strands clients with "VPN on but no internet". curl --interface forces egress out
# singtun0 (SO_BINDTODEVICE), so a dead tunnel FAILS the probe even though the process/iface
# still exist. (ping -I only sets the source addr -> the kernel may route the probe out the
# WAN -> false-OK; do not use it here.) No curl on this router -> skip the probe (fall back
# to liveness, no regression).
tunnel_ok(){
  command -v curl >/dev/null 2>&1 || return 0
  for _t in 1 2 3; do curl -s --max-time 5 --interface singtun0 -o /dev/null http://1.1.1.1 2>/dev/null && return 0; sleep 1; done; return 1
}

if ip link show singtun0 >/dev/null 2>&1 && pidof sing-box >/dev/null 2>&1 && tunnel_ok; then
  # tunnel UP and actually passing traffic -> policy-route LAN through it
  ip route show table 2022 2>/dev/null | grep -q "$LAN" || ip route add "$LAN" dev br-lan table 2022 2>/dev/null
  ip rule show 2>/dev/null | grep -q "from $LAN lookup 2022" || ip rule add from "$LAN" lookup 2022 pref 500 2>/dev/null
  iptables -C FORWARD -i br-lan -o singtun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i br-lan -o singtun0 -j ACCEPT
  iptables -t nat -C POSTROUTING -o singtun0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o singtun0 -j MASQUERADE
else
  # tunnel DOWN or up-but-dead -> if killswitch is OFF, FAIL-OPEN: drop the policy rule so
  # LAN uses the main table (normal internet). If killswitch is ON, ks-sync enforces the block.
  KS=$(uci -q get route_policy.@rule[0].killswitch)
  if [ "$KS" != "1" ]; then
    while ip rule del from "$LAN" lookup 2022 pref 500 2>/dev/null; do :; done
  fi
fi
