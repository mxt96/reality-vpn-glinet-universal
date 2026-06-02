#!/bin/sh
# Refresh egress IP + geo cache for the panel/tab header.
# Reports the TUNNEL egress (queried THROUGH sing-box socks 127.0.0.1:2080) when the
# VPN is up; falls back to the router's own egress when the tunnel/socks is down
# (VPN off). Cheap; runs via cron (5 min) + on server switch.
SOCKS="127.0.0.1:2080"
q() { curl -4 -s --max-time 6 --socks5-hostname "$SOCKS" "$@" 2>/dev/null; }
d() { curl -4 -s --max-time 6 "$@" 2>/dev/null; }
EG=$(q ipv4.icanhazip.com); VIA=tunnel
[ -z "$EG" ] && { EG=$(d ipv4.icanhazip.com); VIA=direct; }
if [ "$VIA" = tunnel ]; then
  GEO=$(q 'http://ip-api.com/json/?fields=country,city')
  TC=$(curl -4 -s -o /dev/null -w '%{time_starttransfer}' --max-time 6 --socks5-hostname "$SOCKS" http://www.gstatic.com/generate_204 2>/dev/null)
else
  GEO=$(d 'http://ip-api.com/json/?fields=country,city')
  TC=$(curl -4 -s -o /dev/null -w '%{time_starttransfer}' --max-time 6 http://www.gstatic.com/generate_204 2>/dev/null)
fi
CO=$(printf '%s' "$GEO" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
CI=$(printf '%s' "$GEO" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
PG=$(awk "BEGIN{printf \"%d\", ${TC:-0}*1000}")
[ -n "$EG" ] && echo "$(date +%s)|$EG|$CO|$CI|$PG" > /tmp/lk-geo
