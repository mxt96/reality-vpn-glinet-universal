#!/bin/sh
# del-server.sh <tag> — remove servers/<tag>.json and rebuild.
SBDIR=${SBDIR:-/etc/sing-box}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -d "$SBDIR/servers" ] || SBDIR="$DIR"
TAG="$1"
[ -z "$TAG" ] && { echo "usage: del-server.sh <tag>  (see list-servers.sh)" >&2; exit 2; }
case "$TAG" in ""|*[!A-Za-z0-9._-]*|.*) echo "invalid server tag" >&2; exit 2 ;; esac
if ! mkdir "$SBDIR/.servers.lock" 2>/dev/null; then
  echo "Server update already running" >&2; exit 1
fi
BACKUP=""; COMMITTED=0
cleanup(){
  if [ "$COMMITTED" = 0 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ] && [ ! -f "$F" ]; then
    mv "$BACKUP" "$F" || { echo "Restore failed; server backup: $BACKUP" >&2; return 1; }
    sh "$REBUILD" >/dev/null 2>&1
  fi
  rmdir "$SBDIR/.servers.lock" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
REBUILD="$SBDIR/rebuild.sh"; [ -f "$REBUILD" ] || REBUILD="$DIR/rebuild.sh"
F="$SBDIR/servers/$TAG.json"
[ -f "$F" ] || { echo "no such server: $TAG" >&2; exit 1; }
BACKUP=$(mktemp "$SBDIR/.deleted-server.XXXXXX") || exit 1
mv "$F" "$BACKUP" || { rm -f "$BACKUP"; exit 1; }
R=$(sh "$REBUILD" 2>/dev/null | head -1)
if [ "$R" != OK ]; then
  echo "Server removal rejected; restoring original" >&2; exit 1
fi
COMMITTED=1
rm -f "$BACKUP"
echo "removed $TAG"
