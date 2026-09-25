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
    ks_apply_family iptables || return 1
    if [ -d /proc/sys/net/ipv6 ]; then
      command -v ip6tables >/dev/null 2>&1 || {
        echo "Kill switch requires ip6tables to protect IPv6" >&2
        return 1
      }
      ks_apply_family ip6tables || return 1
    fi
  fi
}

ks_apply_family(){
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" -nL "$KS_CHAIN" >/dev/null 2>&1 || "$1" -N "$KS_CHAIN" || return 1
  # Establish DROP before attaching a new chain; never empty an attached guard.
  "$1" -C "$KS_CHAIN" -j DROP 2>/dev/null || "$1" -A "$KS_CHAIN" -j DROP || return 1
  for ks_iface in br-lan singtun0 tun+ wg+ awg+; do
    "$1" -C "$KS_CHAIN" -o "$ks_iface" -j RETURN 2>/dev/null ||
      "$1" -I "$KS_CHAIN" -o "$ks_iface" -j RETURN || return 1
  done
  "$1" -C FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null ||
    "$1" -I FORWARD -i br-lan -j "$KS_CHAIN"
}

ks_remove_family(){
  command -v "$1" >/dev/null 2>&1 || return 0
  "$1" -nL FORWARD >/dev/null 2>&1 || return 1
  while "$1" -C FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null; do
    "$1" -D FORWARD -i br-lan -j "$KS_CHAIN" || return 1
  done
  if "$1" -nL "$KS_CHAIN" >/dev/null 2>&1; then
    "$1" -F "$KS_CHAIN" && "$1" -X "$KS_CHAIN" || return 1
  fi
  while "$1" -C FORWARD -i br-lan ! -o singtun0 -j DROP 2>/dev/null; do
    "$1" -D FORWARD -i br-lan ! -o singtun0 -j DROP || return 1
  done
  while "$1" -C FORWARD -i br-lan -o br-lan -j ACCEPT 2>/dev/null; do
    "$1" -D FORWARD -i br-lan -o br-lan -j ACCEPT || return 1
  done
}

# Remove both backends, including rules from older versions.
ks_remove(){
  ks_remove_status=0
  if command -v nft >/dev/null 2>&1 && nft list table inet "$KS_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$KS_TABLE" || ks_remove_status=1
  fi
  ks_remove_family iptables || ks_remove_status=1
  ks_remove_family ip6tables || ks_remove_status=1
  return "$ks_remove_status"
}

ks_present_family(){
  "$1" -C FORWARD -i br-lan -j "$KS_CHAIN" 2>/dev/null &&
    "$1" -C "$KS_CHAIN" -j DROP 2>/dev/null
}

# A jump alone is insufficient: the target must block, in both IP families.
ks_present(){
  if ks_is_nft; then nft list table inet "$KS_TABLE" >/dev/null 2>&1; return $?; fi
  ks_present_family iptables || return 1
  if [ -d /proc/sys/net/ipv6 ]; then ks_present_family ip6tables || return 1; fi
}

# Desired state (user intent) — our own flag is the source of truth; mirror into
# GL's native killswitch uci when that rule exists so the built-in UI stays in sync.
ks_desired(){ [ "$(cat "$KS_FLAG" 2>/dev/null)" = "1" ]; }
ks_set_desired(){
  echo "$1" > "$KS_FLAG" || return 1
  uci -q get route_policy.@rule[0].killswitch >/dev/null 2>&1 && \
    { uci -q set route_policy.@rule[0].killswitch="$1"; uci -q commit route_policy; }
  true
}

# VPN desired-on? (the supervisor's source of truth; also read by panel/ + native tab
# to make the VPN toggle sticky through auto-reconnect). Independent of the killswitch.
vpn_desired(){ [ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" = "1" ]; }

# Reconcile live rules with desired state. INDEPENDENT of the VPN's on/off (mason):
# armed -> block holds regardless of whether our tunnel is up; disarmed -> remove.
ks_enforce(){
  if ks_desired; then ks_apply; else ks_remove; fi
}
