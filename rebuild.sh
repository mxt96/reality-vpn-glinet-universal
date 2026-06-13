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
mkdir -p "$SRVDIR"
SRV_OUT=""; SRV_TAGS=""; N=0
for f in "$SRVDIR"/*.json; do
  [ -f "$f" ] || continue
  t=$(basename "$f" .json)
  SRV_OUT="$SRV_OUT,
$(cat "$f")"
  SRV_TAGS="$SRV_TAGS,\"$t\""
  N=$((N+1))
done
cp -f "$CFG" "$CFG.bak" 2>/dev/null
if [ "$N" -eq 0 ]; then
  # no servers yet -> valid direct-only config so the router keeps internet
  OUTBOUNDS='{ "type": "direct", "tag": "direct" }'
  FINAL="direct"
else
  SRV_TAGS_CLEAN=${SRV_TAGS#,}
  OUTBOUNDS="${SRV_OUT#,},
    { \"type\": \"urltest\", \"tag\": \"auto\", \"outbounds\": [${SRV_TAGS_CLEAN}], \"url\": \"https://www.gstatic.com/generate_204\", \"interval\": \"30s\", \"tolerance\": 80 },
    { \"type\": \"selector\", \"tag\": \"select\", \"outbounds\": [\"auto\"${SRV_TAGS}], \"default\": \"auto\" },
    { \"type\": \"direct\", \"tag\": \"direct\" }"
  FINAL="select"
fi
cat > "$CFG" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090" } },
  "dns": {
    "servers": [
      { "tag": "remote", "type": "udp", "server": "8.8.8.8" },
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
# Ensure swap is on before any heavy sing-box exec (RAM-starved routers). install.sh
# creates the swapfile on persistent storage; re-enable it here in case of a reboot
# where rc.local hasn't run yet. SILENT no-op on roomy-RAM boxes / no swapfile (stdout
# MUST stay clean — the panel reads our first stdout line as the OK/FAIL verdict).
for _sw in /mnt/*/reality-swap /tmp/mountd/*/reality-swap /overlay/reality-swap; do
  [ -f "$_sw" ] && ! grep -qF "$_sw" /proc/swaps 2>/dev/null && swapon "$_sw" >/dev/null 2>&1
done

# Validation is CHECK-FIRST so the healthy-router path stays FAST. The panel reads
# rebuild.sh's first stdout line over an RPC with a read timeout; v1.2.7 polled the
# service for up to 12s before printing OK, so on a perfectly fine router (Beryl) the
# RPC timed out and the panel showed "Server config rejected". Fix: if `sing-box check`
# passes (1-2s on any box with enough RAM) -> apply + OK immediately (identical to the
# proven v1.2.6 path). ONLY if check FAILS do we fall back to a RUNTIME probe — on a
# RAM-starved router (E750 128MB) `check` execs the ~58MB binary and gets OOM-killed even
# for a valid config (exit status lies). There we (re)start and trust the Clash API
# (127.0.0.1:9090) coming up (swap from install.sh gives the headroom). Genuinely bad
# config = check fails AND service won't surface -> roll back + CHECK_FAIL.
svc_up() {
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:9090/version" 2>/dev/null && return 0
  command -v pidof >/dev/null 2>&1 && pidof sing-box >/dev/null 2>&1 && return 0
  return 1
}
if "$SB" check -c "$CFG" 2>/tmp/sb-check.err; then
  # valid config — fast path, byte-for-byte the proven v1.2.6 OK branch (healthy routers).
  [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box restart >/dev/null 2>&1
  sleep 6
  sh "$SBDIR/postup.sh" >/dev/null 2>&1
  echo OK
elif [ -x /etc/init.d/sing-box ]; then
  # check FAILED — could be OOM on a starved router (valid config) or a real bad config.
  # Decide by whether the service actually comes up with this config (Clash API answers).
  /etc/init.d/sing-box restart >/dev/null 2>&1
  up=0; i=0
  while [ "$i" -lt 7 ]; do svc_up && { up=1; break; }; sleep 1; i=$((i+1)); done
  if [ "$up" = 1 ]; then
    sh "$SBDIR/postup.sh" >/dev/null 2>&1
    echo OK
  else
    cp -f "$CFG.bak" "$CFG" 2>/dev/null
    /etc/init.d/sing-box restart >/dev/null 2>&1
    echo "CHECK_FAIL"; head -5 /tmp/sb-check.err 2>/dev/null
  fi
else
  # no service manager (test harness / pre-install) and check failed -> reject.
  cp -f "$CFG.bak" "$CFG" 2>/dev/null
  echo "CHECK_FAIL"; head -5 /tmp/sb-check.err 2>/dev/null
fi
