#!/bin/sh
set -eu
SBDIR=${SBDIR:-/etc/sing-box}
. "$SBDIR/runtime-lib.sh"
set_desired(){
  umask 077
  desired_file=$(mktemp "$SBDIR/.desired.XXXXXX")
  printf '%s\n' "$1" > "$desired_file"
  mv "$desired_file" "$SBDIR/vpn.enabled"
}
case "${1:-}" in
 on)
  [ -n "$(ls "$SBDIR"/servers/*.json 2>/dev/null)" ] || { echo 'No servers configured' >&2; exit 1; }
  set_desired 1
  sb_state connecting
  "$SB_SERVICE" start >/dev/null 2>&1
  sb_wait_ready || { sb_state error; echo 'Daemon did not become ready' >&2; exit 1; }
  sb_apply_routes || { sb_state error; exit 1; }
  ;;
 off)
  set_desired 0
  "$SB_SERVICE" stop >/dev/null 2>&1
  sb_apply_routes
  sb_state off
  ;;
 *) exit 2 ;;
esac
echo OK
