#!/bin/sh
# del-server.sh <tag> — remove servers/<tag>.json and rebuild.
SBDIR=${SBDIR:-/etc/sing-box}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -d "$SBDIR/servers" ] || SBDIR="$DIR"
TAG="$1"
[ -z "$TAG" ] && { echo "usage: del-server.sh <tag>  (see list-servers.sh)" >&2; exit 2; }
F="$SBDIR/servers/$TAG.json"
[ -f "$F" ] || { echo "no such server: $TAG" >&2; exit 1; }
rm -f "$F"
echo "removed $TAG"
sh "$SBDIR/rebuild.sh" 2>/dev/null || sh "$DIR/rebuild.sh"
