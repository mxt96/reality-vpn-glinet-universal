#!/bin/sh
set -eu
SBDIR=${SBDIR:-/etc/sing-box}
SB_API=${SB_API:-http://127.0.0.1:9090}
tag=${1:-}
case "$tag" in ''|*[!A-Za-z0-9._-]*|.*) echo 'Invalid selection' >&2; exit 2 ;; esac
lua "$SBDIR/manager.lua" validate-selection "$tag" </dev/null >/dev/null || { echo 'Server or pool unavailable' >&2; exit 1; }
if [ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" = 1 ]; then
  curl --noproxy '*' -fsS --max-time 5 -X PUT "$SB_API/proxies/select" -d "{\"name\":\"$tag\"}" >/dev/null
fi
umask 077
tmp=$(mktemp "$SBDIR/.selected.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$tag" > "$tmp"
mv "$tmp" "$SBDIR/selected"
echo OK
