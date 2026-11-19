#!/bin/sh
# procd owns one supervisor. Cron is only a recovery fallback.
SBDIR=${SBDIR:-/etc/sing-box}
trap 'exit 0' TERM INT
while :; do
  sh "$SBDIR/watchdog.sh"
  sleep 15 & wait $!
done
