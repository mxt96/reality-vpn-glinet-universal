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
mkdir -p "$SRVDIR"
OUT=$(sh "$PARSE" "$LINK" "$TAG") || { echo "parse failed: not a supported/valid reality or hysteria2 link" >&2; exit 1; }
printf '%s\n' "$OUT" > "$SRVDIR/$TAG.json"
echo "saved $SRVDIR/$TAG.json (tag: $TAG)"
sh "$SBDIR/rebuild.sh" 2>/dev/null || sh "$DIR/rebuild.sh"
