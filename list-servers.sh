#!/bin/sh
# list-servers.sh — print configured server tags + type/host (no secrets dumped).
SBDIR=${SBDIR:-/etc/sing-box}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -d "$SBDIR/servers" ] || SBDIR="$DIR"
SRVDIR="$SBDIR/servers"
n=0
for f in "$SRVDIR"/*.json; do
  [ -f "$f" ] || continue
  t=$(basename "$f" .json)
  ty=$(sed -n 's/.*"type": *"\([^"]*\)".*/\1/p' "$f" | head -1)
  hp=$(sed -n 's/.*"server": *"\([^"]*\)".*/\1/p' "$f" | head -1)
  pt=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$f" | head -1)
  printf '%-24s %-10s %s:%s\n' "$t" "$ty" "$hp" "$pt"
  n=$((n+1))
done
[ "$n" -eq 0 ] && echo "(no servers — config is DIRECT-only, VPN off)"
