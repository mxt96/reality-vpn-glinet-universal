#!/bin/sh
# parse-link.sh <share-link> <tag>  -> prints a sing-box outbound JSON object for the link.
# Supports vless://...reality and hysteria2://|hy2://. Offline (busybox/ash). Exit 1 on parse error.
LINK="$1"; TAG="$2"
[ -z "$LINK" ] && exit 1
[ -z "$TAG" ] && TAG="srv-$(date +%s)"
jstr(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }      # JSON-escape a string
afterscheme(){ printf '%s' "$1" | sed 's#^[a-z0-9]*://##'; }
qp(){ printf '%s' "$Q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }

SCHEME=$(printf '%s' "$LINK" | sed -n 's#^\([a-z0-9]*\)://.*#\1#p')
REST=$(afterscheme "$LINK")
FRAG=$(printf '%s' "$REST" | sed -n 's/^[^#]*#\(.*\)$/\1/p')   # name (unused for tag; tag passed in)
REST=${REST%%#*}                                               # strip fragment
USERINFO=$(printf '%s' "$REST" | sed -n 's/^\([^@]*\)@.*/\1/p')
HP=$(printf '%s' "$REST" | sed -n 's/^[^@]*@\([^/?]*\).*/\1/p') # host:port
HOST=${HP%%:*}; PORT=${HP##*:}
Q=$(printf '%s' "$REST" | sed -n 's/^[^?]*?\([^#]*\).*/\1/p')   # query string

case "$SCHEME" in
  vless)
    SEC=$(qp security); SNI=$(qp sni); PBK=$(qp pbk); SID=$(qp sid); FP=$(qp fp); FLOW=$(qp flow)
    [ -z "$FP" ] && FP=chrome
    if [ "$SEC" = "reality" ]; then
      [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USERINFO" ] || [ -z "$PBK" ] && exit 1
      cat <<JSON
{ "type": "vless", "tag": "$(jstr "$TAG")", "server": "$(jstr "$HOST")", "server_port": $PORT,
  "uuid": "$(jstr "$USERINFO")"$( [ -n "$FLOW" ] && printf ', "flow": "%s"' "$(jstr "$FLOW")" ),
  "tls": { "enabled": true, "server_name": "$(jstr "$SNI")", "utls": { "enabled": true, "fingerprint": "$(jstr "$FP")" },
    "reality": { "enabled": true, "public_key": "$(jstr "$PBK")", "short_id": "$(jstr "$SID")" } } }
JSON
    else exit 1; fi
    ;;
  hysteria2|hy2)
    SNI=$(qp sni)
    [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USERINFO" ] && exit 1
    [ -z "$SNI" ] && SNI="$HOST"
    cat <<JSON
{ "type": "hysteria2", "tag": "$(jstr "$TAG")", "server": "$(jstr "$HOST")", "server_port": $PORT,
  "password": "$(jstr "$USERINFO")",
  "tls": { "enabled": true, "server_name": "$(jstr "$SNI")" } }
JSON
    ;;
  *) exit 1;;
esac
