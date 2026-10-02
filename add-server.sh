#!/bin/sh
# add-server.sh '<share-link>' [tag]
# Parse a vless://...security=reality... or hysteria2://... share-link into a sing-box
# outbound and save it as servers/<tag>.json, then rebuild the config.
# Tag defaults to the link's #fragment (URL name) or srv-<timestamp>.
SBDIR=${SBDIR:-/etc/sing-box}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -d "$SBDIR" ] || SBDIR="$DIR"     # run-from-repo fallback (testing)
SRVDIR="$SBDIR/servers"
PARSE="$SBDIR/parse-link.sh"; [ -f "$PARSE" ] || PARSE="$DIR/parse-link.sh"
LINK="$1"; TAG="$2"
if [ -z "$LINK" ]; then
  echo "usage: add-server.sh '<vless://...reality | hysteria2://...>' [tag]" >&2
  exit 2
fi
if [ -z "$TAG" ]; then
  # derive tag from the #fragment (decode %20), else timestamp
  FRAG=$(printf '%s' "$LINK" | sed -n 's/^[^#]*#\(.*\)$/\1/p' | sed 's/%20/ /g')
  TAG=$(printf '%s' "$FRAG" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')
  [ -z "$TAG" ] && TAG="srv-$(date +%s)"
fi
case "$TAG" in ""|*[!A-Za-z0-9._-]*|.*) echo "invalid server tag" >&2; exit 2 ;; esac
if ! mkdir "$SBDIR/.servers.lock" 2>/dev/null; then
  echo "Server update already running" >&2; exit 1
fi
NEWFILE=""; COMMITTED=0
cleanup(){
  if [ "$COMMITTED" = 0 ] && [ -n "$NEWFILE" ]; then
    rm -f "$NEWFILE" || return 1
    sh "$REBUILD" >/dev/null 2>&1
  fi
  rmdir "$SBDIR/.servers.lock" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
REBUILD="$SBDIR/rebuild.sh"; [ -f "$REBUILD" ] || REBUILD="$DIR/rebuild.sh"
mkdir -p "$SRVDIR"
BASE="$TAG"; I=1
while [ -e "$SRVDIR/$TAG.json" ]; do TAG="$BASE-$I"; I=$((I+1)); done
OUT=$(sh "$PARSE" "$LINK" "$TAG") || { echo "parse failed: not a supported/valid reality or hysteria2 link" >&2; exit 1; }
NEWFILE="$SRVDIR/$TAG.json"
printf '%s\n' "$OUT" > "$NEWFILE" || exit 1
R=$(sh "$REBUILD" 2>/dev/null | head -1)
if [ "$R" != OK ]; then
  echo "Server config rejected" >&2; exit 1
fi
COMMITTED=1
echo "saved $SRVDIR/$TAG.json (tag: $TAG)"
