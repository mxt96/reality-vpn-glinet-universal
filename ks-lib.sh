#!/bin/sh
# ks-lib.sh — killswitch backend library (single source of truth).
#
# Why this exists: the killswitch was iptables-only. On GL.iNet routers running
# fw4/nftables (newer firmware, e.g. Mudi GL-E750 / OpenWrt 22+) the `iptables`
# binary can be an nft-compat shim whose rules silently no-op. This lib auto-detects
# fw4(nftables) vs fw3(iptables) and applies the block to the correct backend, so
# panel/, the native GL tab, and the cron enforcer all agree.
#
# Semantics (mason 2026-06-05): the killswitch is an INDEPENDENT guard — NOT tied to
# our VPN's on/off. When ARMED, LAN->WAN egress is allowed ONLY through a VPN tunnel
# (our sing-box singtun0, OR OpenVPN tun*, OR WireGuard wg*/awg*); any direct path is
# dropped. So when you switch our VPN -> OpenVPN, traffic can't leak in the gap: the
# block holds until YOU disarm the killswitch. Disarming restores normal internet.
# The block is a standing rule (re-asserted by cron), so there is no leak window when
# a tunnel drops. Router-originated traffic (its SSH tunnel to the VPS) is in the
# OUTPUT path, never FORWARD -> never blocked, so you can't lock yourself out of mgmt.

SBDIR=${SBDIR:-/etc/sing-box}
KS_TABLE=sb_ks
KS_CHAIN=SB_KS
KS_FLAG="$SBDIR/ks.enabled"

# fw4/nftables present?  (definitive live check — `iptables` exists on fw4 too)
ks_is_nft(){ command -v nft >/dev/null 2>&1 && nft list table inet fw4 >/dev/null 2>&1; }

# Install the guard in the active backend (idempotent). Allow LAN->tunnel + intra-LAN;
# drop everything else leaving the LAN (i.e. any direct/physical-WAN egress).
ks_apply(){
  if ks_is_nft; then
    nft list table inet "$KS_TABLE" >/dev/null 2>&1 && return 0
    nft -f - <<NFT 2>/dev/null
table inet $KS_TABLE {
  chain forward {
    type filter hook forward priority -1; policy accept;
    iifname "br-lan" oifname "br-lan" accept
    iifname "br-lan" oifname "singtun0" accept
    iifname "br-lan" oifname "tun*" accept
    iifname "br-lan" oifname "wg*" accept
    iifname "br-lan" oifname "awg*" accept
    iifname "br-lan" drop
  }
}
NFT
  else
    # dedicated chain: allowed egress RETURNs (normal firewall then forwards it),
    # everything else from the LAN is DROPped -> no direct leak.
    iptables -N "$KS_CHAIN" 2>/dev/null
    iptables -F "$KS_CHAIN"
    iptables -A "$KS_CHAIN" -o br-lan   -j RETURN
    iptables -A "$KS_CHAIN" -o singtun0 -j RETURN
    iptables -A "$KS_CHAIN" -o tun+     -j RETURN
    iptables -A "$KS_CHAIN" -o wg+      -j RETURN
    iptables -A "$KS_CHAIN" -o awg+     -j RETURN
    iptables -A "$KS_CHAIN" -j DROP
    iptables -C FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null || iptables -I FORWARD -i br-lan -j "$KS_CHAIN"
  fi
}

# Remove the guard from BOTH backends (router may have switched / shim present),
# plus any legacy single-rule form from earlier versions.
ks_remove(){
  nft list table inet "$KS_TABLE" >/dev/null 2>&1 && nft delete table inet "$KS_TABLE" 2>/dev/null
  while iptables -D FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null; do :; done
  iptables -F "$KS_CHAIN" 2>/dev/null; iptables -X "$KS_CHAIN" 2>/dev/null
  # legacy rules from the pre-chain version:
  while iptables -D FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null; do :; done
  while iptables -D FORWARD -i br-lan -o br-lan -j ACCEPT 2>/dev/null; do :; done
}

# Is the guard currently installed in the active backend?
ks_present(){
  if ks_is_nft; then nft list table inet "$KS_TABLE" >/dev/null 2>&1; return $?; fi
  iptables -C FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null
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

# Reconcile live rules with desired state. INDEPENDENT of the VPN's on/off (mason):
# armed -> block holds regardless of whether our tunnel is up; disarmed -> remove.
ks_enforce(){
  if ks_desired; then ks_apply; else ks_remove; fi
}
