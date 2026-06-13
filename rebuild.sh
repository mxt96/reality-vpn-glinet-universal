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
# where rc.local hasn't run yet. Cheap no-op on boxes with plenty of RAM / no swapfile.
for _sw in /mnt/*/reality-swap /tmp/mountd/*/reality-swap /overlay/reality-swap; do
  [ -f "$_sw" ] && ! grep -qF "$_sw" /proc/swaps 2>/dev/null && swapon "$_sw" 2>/dev/null
done

# Validate the new config by RUNTIME, not by `sing-box check` alone. On a RAM-starved
# router (E750: 128MB) `check` execs the ~58MB binary and can be OOM-killed even for a
# perfectly valid config — sometimes with EMPTY stderr ("Terminated"), sometimes with a
# Go-runtime "out of memory" / "signal: killed" message — so its exit status LIES, and
# the panel then reports "Server config rejected" for a good config. The ground truth is
# whether sing-box actually loads this config and serves: its Clash API (127.0.0.1:9090)
# answers ONLY after the config parsed and the service came up. So: restart, poll the
# API, trust THAT. `check` is consulted only when the service didn't surface, to (a) let
# a valid-but-slow start still pass and (b) print the real reason for a genuinely bad
# config. Bonus: the common path now does ONE heavy exec (the running daemon), not two.
svc_up() {
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:9090/version" 2>/dev/null && return 0
  command -v pidof >/dev/null 2>&1 && pidof sing-box >/dev/null 2>&1 && return 0
  return 1
}
if [ -x /etc/init.d/sing-box ]; then
  /etc/init.d/sing-box restart 2>/dev/null
  up=0; i=0
  while [ "$i" -lt 12 ]; do svc_up && { up=1; break; }; sleep 1; i=$((i+1)); done
  if [ "$up" = 1 ]; then
    # MUST silence stdout too: on fw4/iptables-nft routers postup's iptables commands
    # print rule lines, which would otherwise pollute this script's output and make
    # callers that read the first line (panel addserver/delserver) misread "OK".
    sh "$SBDIR/postup.sh" >/dev/null 2>&1
    echo OK
  elif "$SB" check -c "$CFG" 2>/tmp/sb-check.err; then
    # service slow to surface (geoip pull / tun race) but the config IS valid -> accept;
    # procd keeps (re)starting it and it comes up once memory settles.
    sh "$SBDIR/postup.sh" >/dev/null 2>&1
    echo OK
  else
    # service didn't come up AND check reports a real error -> genuinely bad config.
    cp -f "$CFG.bak" "$CFG" 2>/dev/null
    /etc/init.d/sing-box restart 2>/dev/null
    echo "CHECK_FAIL"; head -5 /tmp/sb-check.err 2>/dev/null
  fi
else
  # no service manager (test harness / pre-install) -> static check decides.
  if "$SB" check -c "$CFG" 2>/tmp/sb-check.err; then
    sh "$SBDIR/postup.sh" >/dev/null 2>&1
    echo OK
  else
    cp -f "$CFG.bak" "$CFG" 2>/dev/null
    echo "CHECK_FAIL"; head -5 /tmp/sb-check.err 2>/dev/null
  fi
fi
