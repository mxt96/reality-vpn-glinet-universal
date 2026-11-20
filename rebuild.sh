#!/bin/sh
# rebuild.sh (universal) — regenerate sing-box config from user servers in
# /etc/sing-box/servers/*.json. Nothing is hardcoded: with no servers the config is
# valid and routes DIRECT (VPN off, internet stays up); with servers it builds an
# urltest "auto" + a "select" selector over them. Validates with `sing-box check`,
# restarts the service, re-applies LAN forwarding. Prints OK or CHECK_FAIL.
#
# DNS uses the sing-box >=1.12 schema:
#   servers: [{ "type":"udp", "server":"8.8.8.8" }, ...]   (NOT the legacy "address")
#   route.default_domain_resolver -> a direct DNS, so that hostname server addresses
#   in outbounds can be resolved (FATAL to omit on 1.12+; this is the known bug fix).
SBDIR=${SBDIR:-/etc/sing-box}
SRVDIR="$SBDIR/servers"
CFG="$SBDIR/reality_full.json"
SB="$SBDIR/sing-box"
[ -x "$SB" ] || SB=$(command -v sing-box || echo "$SB")
umask 077
mkdir -p "$SRVDIR"
if [ -r "$SBDIR/runtime-lib.sh" ]; then . "$SBDIR/runtime-lib.sh"; else . "$(dirname "$0")/runtime-lib.sh"; fi
LOCK="$SBDIR/.rebuild.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  case "$owner" in ''|*[!0-9]*) echo CHECK_FAIL; echo 'Configuration update is busy'; exit 1 ;; esac
  if kill -0 "$owner" 2>/dev/null; then echo CHECK_FAIL; echo 'Configuration update is busy'; exit 1; fi
  rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { echo CHECK_FAIL; exit 1; }
fi
CANDIDATE=$(mktemp "$SBDIR/.config.XXXXXX") || { rm -f "$LOCK/pid"; rmdir "$LOCK"; exit 1; }
echo $$ > "$LOCK/pid"
trap 'rm -f "$CANDIDATE" "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM
SRV_OUT=""; SRV_TAGS=""; REA_TAGS=""; HY2_TAGS=""; N=0
for f in "$SRVDIR"/*.json; do
  [ -f "$f" ] || continue
  t=$(basename "$f" .json)
  ty=$(grep -oE '"type"[ ]*:[ ]*"[a-z0-9]+"' "$f" | head -1 | sed -E 's/.*"([a-z0-9]+)"$/\1/')
  SRV_OUT="$SRV_OUT,
$(cat "$f")"
  SRV_TAGS="$SRV_TAGS,\"$t\""
  # bucket by protocol family so "auto" can be filtered (Reality = vless, Hysteria2)
  case "$ty" in
    hysteria2) HY2_TAGS="$HY2_TAGS,\"$t\"" ;;
    vless)     REA_TAGS="$REA_TAGS,\"$t\"" ;;
  esac
  N=$((N+1))
done
SELECTED=$(cat "$SBDIR/selected" 2>/dev/null)
case "$SELECTED" in ''|*[!A-Za-z0-9._-]*|.*) SELECTED=auto ;; esac
case ",$SRV_TAGS," in *\"$SELECTED\"*) : ;; *)
  case "$SELECTED" in auto|auto-reality|auto-hy2|auto-fav) : ;; *) SELECTED=auto ;; esac
esac
if [ "$N" -eq 0 ]; then
  # no servers yet -> valid direct-only config so the router keeps internet
  OUTBOUNDS='{ "type": "direct", "tag": "direct" }'
  FINAL="direct"
else
  SRV_TAGS_CLEAN=${SRV_TAGS#,}
  # Protocol-filtered "auto" groups — built ONLY when ≥1 server of that family exists
  # (an empty urltest is invalid). They let the panel's Protocol filter pick the best
  # server within one protocol. select lists them so they're switchable.
  FILT_OUT=""; SEL_EXTRA=""
  if [ -n "$REA_TAGS" ]; then
    FILT_OUT="$FILT_OUT,
    { \"type\": \"urltest\", \"tag\": \"auto-reality\", \"outbounds\": [${REA_TAGS#,}], \"url\": \"https://www.gstatic.com/generate_204\", \"interval\": \"30s\", \"tolerance\": 80, \"interrupt_exist_connections\": true }"
    SEL_EXTRA="$SEL_EXTRA,\"auto-reality\""
  fi
  if [ -n "$HY2_TAGS" ]; then
    FILT_OUT="$FILT_OUT,
    { \"type\": \"urltest\", \"tag\": \"auto-hy2\", \"outbounds\": [${HY2_TAGS#,}], \"url\": \"https://www.gstatic.com/generate_204\", \"interval\": \"30s\", \"tolerance\": 80, \"interrupt_exist_connections\": true }"
    SEL_EXTRA="$SEL_EXTRA,\"auto-hy2\""
  fi
  # Favorites pool — urltest over user-starred servers (file /etc/sing-box/favorites,
  # one tag per line). "Auto ★" picks the best among ONLY the servers mason marked,
  # not all 90+ from a subscription. Built only when ≥1 favorite still exists.
  FAV_TAGS=""
  if [ -f "$SBDIR/favorites" ]; then
    while IFS= read -r ft; do [ -z "$ft" ] && continue; [ -f "$SRVDIR/$ft.json" ] && FAV_TAGS="$FAV_TAGS,\"$ft\""; done < "$SBDIR/favorites"
  fi
  if [ -n "$FAV_TAGS" ]; then
    FILT_OUT="$FILT_OUT,
    { \"type\": \"urltest\", \"tag\": \"auto-fav\", \"outbounds\": [${FAV_TAGS#,}], \"url\": \"https://www.gstatic.com/generate_204\", \"interval\": \"30s\", \"tolerance\": 80, \"interrupt_exist_connections\": true }"
    SEL_EXTRA="$SEL_EXTRA,\"auto-fav\""
  fi
  OUTBOUNDS="${SRV_OUT#,},
    { \"type\": \"urltest\", \"tag\": \"auto\", \"outbounds\": [${SRV_TAGS_CLEAN}], \"url\": \"https://www.gstatic.com/generate_204\", \"interval\": \"30s\", \"tolerance\": 80, \"interrupt_exist_connections\": true }${FILT_OUT},
    { \"type\": \"selector\", \"tag\": \"select\", \"outbounds\": [\"auto\"${SEL_EXTRA}${SRV_TAGS}], \"default\": \"$SELECTED\" },
    { \"type\": \"direct\", \"tag\": \"direct\" }"
  FINAL="select"
fi
# A removed pool cannot be used as the selector default.
case "$SELECTED" in
 auto-reality) [ -n "$REA_TAGS" ] || SELECTED=auto ;;
 auto-hy2) [ -n "$HY2_TAGS" ] || SELECTED=auto ;;
 auto-fav)
  if [ "$N" -gt 0 ] && [ -z "$FAV_TAGS" ]; then
    echo CHECK_FAIL; echo 'Choose a favorite or explicitly select a different pool'; exit 1
  fi ;;
esac
OUTBOUNDS=$(printf '%s' "$OUTBOUNDS" | sed 's/"default": "[^"]*"/"default": "'"$SELECTED"'"/')
DETOUR=""; [ "$FINAL" = direct ] || DETOUR=", \"detour\": \"$FINAL\""
cat > "$CANDIDATE" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090" }, "cache_file": { "enabled": true, "path": "$SBDIR/cache.db" } },
  "dns": {
    "servers": [
      { "tag": "remote", "type": "udp", "server": "8.8.8.8"$DETOUR },
      { "tag": "direct-dns", "type": "udp", "server": "1.1.1.1" }
    ],
    "final": "remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "singtun0", "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "system" },
    { "type": "mixed", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [
    $OUTBOUNDS
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "$FINAL",
    "auto_detect_interface": true,
    "default_domain_resolver": "direct-dns"
  }
}
JSON
if [ -f "$SBDIR/manager.lua" ]; then
  if ! lua "$SBDIR/manager.lua" render "$CANDIDATE" >/dev/null 2>"$SBDIR/check.err"; then
    echo CHECK_FAIL; echo 'Manager configuration rejected'; exit 1
  fi
fi
# Build/validate a candidate before replacing the live file. A successful check
# is necessary, but daemon readiness is also checked after applying.
if ! "$SB" check -c "$CANDIDATE" 2>"$SBDIR/check.err"; then
  echo CHECK_FAIL; head -5 "$SBDIR/check.err"; exit 1
fi
if [ "${REBUILD_CHECK_ONLY:-0}" = 1 ]; then
  mv "$CANDIDATE" "$CFG"
  echo OK; exit 0
fi
[ ! -f "$CFG" ] || cp -p "$CFG" "$CFG.bak" || exit 1
mv "$CANDIDATE" "$CFG" || exit 1
if [ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" = 0 ] || [ "$N" = 0 ]; then
  echo OK; exit 0
fi
if [ ! -x "$SB_SERVICE" ]; then
  echo CHECK_FAIL; echo 'Service manager unavailable'; exit 1
fi
sb_state connecting
if "$SB_SERVICE" restart >/dev/null 2>&1 && sb_wait_ready && sb_apply_routes; then
  sb_state connecting
  echo OK
else
  [ ! -f "$CFG.bak" ] || cp -p "$CFG.bak" "$CFG"
  "$SB_SERVICE" restart >/dev/null 2>&1
  sb_state error
  echo CHECK_FAIL; echo 'Daemon did not become ready; previous configuration restored'
  exit 1
fi
