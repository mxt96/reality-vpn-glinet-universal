#!/bin/sh
SBDIR=${SBDIR:-/etc/sing-box}
. "$SBDIR/runtime-lib.sh" || exit 1
lock="$SBDIR/.supervisor.lock"
if ! mkdir "$lock" 2>/dev/null; then
  pid=$(cat "$lock/pid" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) exit 0 ;; esac
  kill -0 "$pid" 2>/dev/null && exit 0
  rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || exit 0
fi
echo $$ > "$lock/pid"
trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM
if [ -f "$SBDIR/ks-lib.sh" ]; then . "$SBDIR/ks-lib.sh"; ks_enforce; fi

if [ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" != 1 ] ||
   [ -z "$(ls "$SBDIR"/servers/*.json 2>/dev/null)" ]; then
  "$SB_SERVICE" stop >/dev/null 2>&1
  sb_state off
  exit 0
fi
now=$(date +%s)
last=$(cat "$SBDIR/restart.ts" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if ! sb_ready; then
  sb_state connecting
  if [ $((now-last)) -ge 30 ]; then
    echo "$now" > "$SBDIR/restart.ts"
    "$SB_SERVICE" restart >/dev/null 2>&1
    sb_wait_ready || { sb_state error; exit 1; }
  else
    exit 0
  fi
fi
sb_apply_routes || { sb_state error; exit 1; }
if sb_health; then
  echo 0 > "$SBDIR/health.failures"
  sb_state connected
else
  sb_state reconnecting
  n=$(cat "$SBDIR/health.failures" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1)); echo "$n" > "$SBDIR/health.failures"
  if [ "$n" -ge 3 ] && [ $((now-last)) -ge 120 ]; then
    echo "$now" > "$SBDIR/restart.ts"
    "$SB_SERVICE" restart >/dev/null 2>&1
    sb_wait_ready && sb_apply_routes
  fi
fi
