#!/bin/sh
# Killswitch sync. SAFETY: only enforce the LAN block when the VPN is actually ON
# (sing-box running). VPN intentionally OFF -> never block, so a stuck "killswitch
# ON" flag can NEVER strand the router without internet. Flag = GL's own
# route_policy.@rule[0].killswitch (one switch, two places).
F=$(uci -q get route_policy.@rule[0].killswitch)
VPN_ON=0; pidof sing-box >/dev/null 2>&1 && VPN_ON=1
if [ "$F" = "1" ] && [ "$VPN_ON" = "1" ]; then
  iptables -C FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null || iptables -I FORWARD -i br-lan ! -o singtun0 -j DROP
  iptables -C FORWARD -i br-lan -o br-lan -j ACCEPT 2>/dev/null || iptables -I FORWARD -i br-lan -o br-lan -j ACCEPT
else
  while iptables -D FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null; do :; done
  while iptables -D FORWARD -i br-lan -o br-lan -j ACCEPT 2>/dev/null; do :; done
fi
