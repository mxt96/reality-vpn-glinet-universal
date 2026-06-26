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
  # fw4/nftables routers: the iptables rules above land in the legacy ip filter/nat tables
  # that the `inet fw4` ruleset IGNORES, so LAN clients still get dropped by fw4's
  # `policy drop` on the forward hook. The install-time hotplug hook adds the fw4 rules but
  # only re-fires on firewall RELOAD events — if fw4 flushes them without a following reload,
  # nothing restores them and LAN clients get "VPN on, Wi-Fi connected, but no internet".
  # Re-assert them here (every 2 min) so the cron self-heals the fw4 path too. Idempotent.
  if nft list table inet fw4 >/dev/null 2>&1; then
    nft -a list chain inet fw4 forward 2>/dev/null | grep -q 'oifname "singtun0" accept' || nft insert rule inet fw4 forward oifname singtun0 accept 2>/dev/null
    nft -a list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "singtun0" accept'  || nft insert rule inet fw4 forward iifname singtun0 accept 2>/dev/null
    nft -a list chain inet fw4 srcnat  2>/dev/null | grep -q 'oifname "singtun0" masquerade' || nft add rule inet fw4 srcnat oifname singtun0 masquerade 2>/dev/null
  fi
else
  # tunnel DOWN or up-but-dead -> if killswitch is OFF, FAIL-OPEN: drop the policy rule so
  # LAN uses the main table (normal internet). If killswitch is ON, KEEP the route (the
  # standing sb_ks block holds traffic shut, no leak) so the moment sing-box reconnects /
  # urltest fails over to another favorite, LAN traffic flows again with no manual step.
  # Source of truth = ks-lib's ks_desired ($SBDIR/ks.enabled), NOT the uci mirror: that
  # mirror is absent on routers without GL's native killswitch rule, and reading only it
  # caused a fail-open even while the killswitch was armed (split-brain leak).
  SBDIR=${SBDIR:-/etc/sing-box}
  KSON=0
  if [ -r "$SBDIR/ks-lib.sh" ]; then
    . "$SBDIR/ks-lib.sh"; ks_desired && KSON=1
  else
    [ "$(cat "$SBDIR/ks.enabled" 2>/dev/null)" = "1" ] && KSON=1
    [ "$(uci -q get route_policy.@rule[0].killswitch 2>/dev/null)" = "1" ] && KSON=1
  fi
  if [ "$KSON" != "1" ]; then
    while ip rule del from "$LAN" lookup 2022 pref 500 2>/dev/null; do :; done
  fi
fi
