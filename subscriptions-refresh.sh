#!/bin/sh
SBDIR=${SBDIR:-/etc/sing-box}
interval=$(lua -e 'local j=require "cjson"; local f=io.open(arg[0]); local s=f and j.decode(f:read("*a")) or {}; print(s.subscription_hours or 6); os.exit(0)' "$SBDIR/settings.json" 2>/dev/null)
case "$interval" in ''|*[!0-9]*) interval=6 ;; esac
now=$(date +%s)
for f in "$SBDIR"/subs/*.url; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .url)
  last=$(cat "$SBDIR/subs/$id.upd" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now-last)) -lt $((interval*3600)) ] || sh "$SBDIR/sub-store.sh" refresh "$id"
done
