#!/bin/sh
# ks-lib.sh — killswitch backend library (single source of truth).
#
# Why this exists: the killswitch was iptables-only. On GL.iNet routers running
# fw4/nftables (newer firmware, e.g. Beryl 7 / MT3600BE) the `iptables` binary is
# an nft-compat shim whose rules can silently no-op -> "killswitch doesn't engage".
# This lib auto-detects fw4(nftables) vs fw3(iptables) and applies the block to the
# correct backend, so panel/, the native GL tab, and the cron enforcer all agree.
#
# Semantics: when KS is desired AND the VPN is desired ON, block LAN->WAN unless the
# packet egresses via the sing-box tun (singtun0). This is a TRUE killswitch: it
# holds even if sing-box momentarily dies (no clear-text leak), and the supervisor
# brings the tunnel back. Turning the VPN OFF (or KS OFF) releases the block, so a
# stuck flag can never strand the router. Router-originated traffic (its SSH tunnel
# to the VPS) is in the OUTPUT path, never the FORWARD path -> never blocked.

SBDIR=${SBDIR:-/etc/sing-box}
KS_TABLE=sb_ks
KS_FLAG="$SBDIR/ks.enabled"
VPN_FLAG="$SBDIR/vpn.enabled"

# fw4/nftables present?  (definitive live check — `iptables` exists on fw4 too)
ks_is_nft(){ command -v nft >/dev/null 2>&1 && nft list table inet fw4 >/dev/null 2>&1; }

# Install the block in the active backend (idempotent).
ks_apply(){
  if ks_is_nft; then
    nft list table inet "$KS_TABLE" >/dev/null 2>&1 && return 0
    nft -f - <<NFT 2>/dev/null
table inet $KS_TABLE {
  chain forward {
    type filter hook forward priority -1; policy accept;
    iifname "br-lan" oifname "br-lan" accept
    oifname "singtun0" accept
    iifname "br-lan" oifname != "singtun0" drop
  }
}
NFT
  else
    iptables -C FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null || {
      iptables -I FORWARD -i br-lan ! -o singtun0 -j DROP
      iptables -I FORWARD -i br-lan -o br-lan -j ACCEPT
    }
  fi
}

# Remove the block from BOTH backends (router may have switched / shim present).
ks_remove(){
  nft list table inet "$KS_TABLE" >/dev/null 2>&1 && nft delete table inet "$KS_TABLE" 2>/dev/null
  while iptables -D FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null; do :; done
  while iptables -D FORWARD -i br-lan -o br-lan -j ACCEPT 2>/dev/null; do :; done
}

# Is the block currently installed in the active backend?
ks_present(){
  if ks_is_nft; then nft list table inet "$KS_TABLE" >/dev/null 2>&1; return $?; fi
  iptables -C FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null
}

# Desired state (user intent) — our own flag is the source of truth; mirror into
# GL's native killswitch uci when that rule exists so the built-in UI stays in sync.
ks_desired(){ [ "$(cat "$KS_FLAG" 2>/dev/null)" = "1" ]; }
ks_set_desired(){
  echo "$1" > "$KS_FLAG"
  uci -q get route_policy.@rule[0].killswitch >/dev/null 2>&1 && \
    { uci -q set route_policy.@rule[0].killswitch="$1"; uci -q commit route_policy; }
  true
}
vpn_desired(){ [ "$(cat "$VPN_FLAG" 2>/dev/null)" = "1" ]; }

# Reconcile live rules with desired state. Block only when KS on AND VPN wanted on.
ks_enforce(){
  if ks_desired && vpn_desired; then ks_apply; else ks_remove; fi
}
