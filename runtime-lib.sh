#!/bin/sh
# Shared lifecycle/health helpers. Never infer connectivity from a PID or ICMP.
SBDIR=${SBDIR:-/etc/sing-box}
SB_API=${SB_API:-http://127.0.0.1:9090}
SB_SERVICE=${SB_SERVICE:-/etc/init.d/sing-box}
sb_ready() {
  ip link show singtun0 >/dev/null 2>&1 || return 1
  curl --noproxy '*' -fsS --max-time 2 "$SB_API/version" 2>/dev/null | grep -q '"version"'
}
sb_wait_ready() {
  _i=0
  while [ "$_i" -lt "${SB_START_TIMEOUT:-15}" ]; do
    sb_ready && return 0
    sleep 1; _i=$((_i+1))
  done
  return 1
}
sb_health() {
  for _url in ${SB_HEALTH_URLS:-https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204}; do
    _code=$(curl --noproxy '' -s --max-time 5 --connect-timeout 3 --socks5-hostname 127.0.0.1:2080 -o /dev/null -w '%{http_code}' "$_url" 2>/dev/null)
    case "$_code" in 200|204) return 0 ;; esac
  done
  return 1
}
sb_state() {
  _health_file=$(mktemp "$SBDIR/.health.XXXXXX") || return 1
  printf '%s|%s\n' "$(date +%s)" "$1" > "$_health_file"
  mv "$_health_file" "$SBDIR/health"
}
sb_apply_routes() {
  [ "${SB_SKIP_APPLY:-0}" != 1 ] || return 0
  if [ -f "$SBDIR/manager.lua" ]; then
    _attempt=0
    while [ "$_attempt" -lt 3 ]; do
      lua "$SBDIR/manager.lua" apply </dev/null >/dev/null 2>&1 && return 0
      _attempt=$((_attempt+1)); sleep 1
    done
    return 1
  else
    sh "$SBDIR/postup.sh" >/dev/null 2>&1
  fi
}
