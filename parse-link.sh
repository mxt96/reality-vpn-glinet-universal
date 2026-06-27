#!/bin/sh
# parse-link.sh <share-link> <tag>  ->  prints a sing-box outbound JSON object.
#
# Universal share-link parser (offline, busybox/ash). Supports:
#   vless://   reality | tls | none, transports tcp/ws/grpc/httpupgrade/http
#   vmess://   (base64-JSON), ws/grpc/tcp + tls
#   trojan://  tls (+ ws/grpc)
#   ss://      shadowsocks (SIP002 and legacy base64)
#   hysteria2://|hy2://   + obfs(salamander)/insecure/alpn
#   tuic://    uuid:password
# Tolerates panel param-name differences (pbk/publicKey, sid/shortId, fp/fingerprint,
# sni/serverName/peer/host). URL-decodes params. Handles IPv6 [host]:port.
# On failure: prints a human reason to stderr and exits non-zero.

LINK="$1"; TAG="$2"
[ -z "$LINK" ] && { echo "empty link" >&2; exit 1; }
[ -z "$TAG" ] && TAG="srv-$(date +%s)"

die(){ echo "$1" >&2; exit 1; }
jstr(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# URL-decode (%XX and +) — portable (busybox/dash/gawk), no strtonum
urldec(){ printf '%s' "$1" | awk '
  BEGIN{ for(i=0;i<16;i++){ x=sprintf("%x",i); H[x]=i; H[toupper(x)]=i } }
  { gsub(/\+/," "); r=""; n=length($0); i=1;
    while(i<=n){ c=substr($0,i,1);
      if(c=="%" && i+2<=n){ a=substr($0,i+1,1); b=substr($0,i+2,1);
        if((a in H)&&(b in H)){ r=r sprintf("%c",H[a]*16+H[b]); i+=3; continue } }
      r=r c; i++ } print r }'; }
b64dec(){ # tolerant base64 decode (pad + url-safe). busybox often lacks `base64`
  # but ships openssl (installer requires it) -> use whichever is present.
  s=$(printf '%s' "$1" | tr '_-' '/+' | tr -d '\n\r ')
  case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
  if command -v base64 >/dev/null 2>&1; then printf '%s' "$s" | base64 -d 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then printf '%s' "$s" | openssl base64 -d -A 2>/dev/null
  fi
}
# JSON field from a flat-ish JSON blob: jget <blob> <key>  (string or number)
jget(){ _v=$(printf '%s' "$1" | sed -n 's/.*"'"$2"'"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$_v" ] && _v=$(printf '%s' "$1" | sed -n 's/.*"'"$2"'"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)
  printf '%s' "$_v"; }

QS=""
qp(){ for k in "$@"; do v=$(printf '%s' "$QS" | tr '&' '\n' | sed -n "s/^$k=//p" | head -1); [ -n "$v" ] && { urldec "$v"; return; }; done; }

SCHEME=$(printf '%s' "$LINK" | sed -n 's#^\([a-zA-Z0-9]*\)://.*#\1#p' | tr 'A-Z' 'a-z')
[ -z "$SCHEME" ] && die "no scheme (expected vless:// vmess:// trojan:// ss:// hysteria2:// tuic://)"
# xhttp / splithttp are Xray-only transports sing-box can't speak — reject so we never
# emit a transport-less (broken) server that imports OK but never connects.
case "$LINK" in *type=xhttp*|*type=splithttp*) die "transport xhttp/splithttp not supported by sing-box" ;; esac
BODY=$(printf '%s' "$LINK" | sed 's#^[a-zA-Z0-9]*://##')

# split out the #fragment (name); for vmess the body is base64 so handle separately
if [ "$SCHEME" != "vmess" ]; then
  BODY=${BODY%%#*}
  QS=$(printf '%s' "$BODY" | sed -n 's/^[^?]*?\(.*\)$/\1/p')
  MAIN=${BODY%%\?*}
  USERINFO=$(printf '%s' "$MAIN" | sed -n 's/^\([^@]*\)@.*/\1/p')
  HOSTPORT=$(printf '%s' "$MAIN" | sed 's/^[^@]*@//')
  # drop any trailing "/path" (e.g. hysteria2://pass@host:8443/?sni=…) so the port
  # parse below doesn't capture the slash -> "server_port": 8443/ -> invalid JSON.
  HOSTPORT=${HOSTPORT%%/*}
  case "$HOSTPORT" in
    \[*\]:*) HOST=$(printf '%s' "$HOSTPORT" | sed -n 's/^\[\(.*\)\]:.*/\1/p'); PORT=${HOSTPORT##*:} ;;
    \[*\])   HOST=$(printf '%s' "$HOSTPORT" | sed -n 's/^\[\(.*\)\]$/\1/p'); PORT= ;;
    *)       HOST=${HOSTPORT%%:*}; PORT=${HOSTPORT##*:} ;;
  esac
  # With no ':' in HOSTPORT, ${HOSTPORT##*:} returns the whole host -> PORT becomes the
  # hostname (non-empty, so the per-scheme "[ -z $PORT ]" guards pass) -> we'd emit
  # "server_port": <hostname> = invalid JSON ("Server config rejected"). Require a numeric port.
  case "$PORT" in ""|*[!0-9]*) die "missing or non-numeric port" ;; esac
fi

# ---- reusable TLS + transport builders ------------------------------------
# build_tls <sni> <insecure 1/empty> <alpn-csv> <fp> <reality-pbk> <reality-sid>
build_tls(){
  _sni="$1"; _ins="$2"; _alpn="$3"; _fp="$4"; _pbk="$5"; _sid="$6"; _quic="$7"
  [ -z "$_fp" ] && _fp=chrome
  _out="\"tls\": { \"enabled\": true, \"server_name\": \"$(jstr "$_sni")\""
  [ "$_ins" = "1" ] && _out="$_out, \"insecure\": true"
  if [ -n "$_alpn" ]; then
    _a=$(printf '%s' "$_alpn" | awk -F, '{for(i=1;i<=NF;i++){printf (i>1?",":"")"\""$i"\""}}')
    _out="$_out, \"alpn\": [$_a]"
  fi
  # uTLS only applies to TCP-based TLS. QUIC transports (hysteria2/tuic) reject a
  # utls block -> sing-box fails to build the outbound and `sing-box check` errors,
  # so rebuild.sh reverts to direct and the panel "add server" silently fails.
  [ -z "$_quic" ] && _out="$_out, \"utls\": { \"enabled\": true, \"fingerprint\": \"$(jstr "$_fp")\" }"
  [ -n "$_pbk" ] && _out="$_out, \"reality\": { \"enabled\": true, \"public_key\": \"$(jstr "$_pbk")\", \"short_id\": \"$(jstr "$_sid")\" }"
  printf '%s }' "$_out"
}
# build_transport <type> <path> <hostheader> <servicename>  (empty/tcp -> nothing)
build_transport(){
  _t="$1"; _path="$2"; _hh="$3"; _svc="$4"
  case "$_t" in
    ws)
      _o="\"transport\": { \"type\": \"ws\", \"path\": \"$(jstr "${_path:-/}")\""
      [ -n "$_hh" ] && _o="$_o, \"headers\": { \"Host\": \"$(jstr "$_hh")\" }"
      printf '%s }' "$_o" ;;
    httpupgrade)
      _o="\"transport\": { \"type\": \"httpupgrade\", \"path\": \"$(jstr "${_path:-/}")\""
      [ -n "$_hh" ] && _o="$_o, \"host\": \"$(jstr "$_hh")\""
      printf '%s }' "$_o" ;;
    grpc)
      printf '"transport": { "type": "grpc", "service_name": "%s" }' "$(jstr "${_svc:-$_path}")" ;;
    http|h2)
      _o="\"transport\": { \"type\": \"http\", \"path\": \"$(jstr "${_path:-/}")\""
      [ -n "$_hh" ] && _o="$_o, \"host\": [\"$(jstr "$_hh")\"]"
      printf '%s }' "$_o" ;;
    *) : ;;
  esac
}

emit(){ printf '%s\n' "$1"; exit 0; }

case "$SCHEME" in
  vless)
    [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USERINFO" ] && die "vless: missing uuid/host/port"
    SEC=$(qp security); SNI=$(qp sni serverName peer); PBK=$(qp pbk publicKey)
    SID=$(qp sid shortId shortIds); FP=$(qp fp fingerprint); FLOW=$(qp flow)
    NET=$(qp type net); PATHV=$(qp path); HHDR=$(qp host); SVC=$(qp serviceName servicename)
    ALPN=$(qp alpn); INS=$(qp allowInsecure insecure)
    { [ "$INS" = "1" ] || [ "$INS" = "true" ]; } && INS=1 || INS=
    [ -z "$NET" ] && NET=tcp
    [ -z "$SNI" ] && SNI="$HHDR"; [ -z "$SNI" ] && SNI="$HOST"
    TLSBLK=""; case "$SEC" in
      reality) [ -z "$PBK" ] && die "vless reality: missing pbk/publicKey"; TLSBLK=$(build_tls "$SNI" "" "$ALPN" "$FP" "$PBK" "$SID") ;;
      tls|xtls) TLSBLK=$(build_tls "$SNI" "$INS" "$ALPN" "$FP" "" "") ;;
      none|"") TLSBLK="" ;;
      *) die "vless: unsupported security '$SEC'" ;;
    esac
    TRBLK=$(build_transport "$NET" "$PATHV" "$HHDR" "$SVC")
    J="{ \"type\": \"vless\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$HOST")\", \"server_port\": $PORT, \"uuid\": \"$(jstr "$USERINFO")\""
    [ -n "$FLOW" ] && J="$J, \"flow\": \"$(jstr "$FLOW")\""
    [ -n "$TLSBLK" ] && J="$J, $TLSBLK"
    [ -n "$TRBLK" ] && J="$J, $TRBLK"
    emit "$J }"
    ;;
  vmess)
    RAW=$(printf '%s' "$BODY" | sed 's/#.*//')
    JS=$(b64dec "$RAW"); [ -z "$JS" ] && die "vmess: bad base64"
    ADD=$(jget "$JS" add); VPORT=$(jget "$JS" port); ID=$(jget "$JS" id)
    AID=$(jget "$JS" aid); NET=$(jget "$JS" net); HHDR=$(jget "$JS" host)
    PATHV=$(jget "$JS" path); TLSV=$(jget "$JS" tls); SNI=$(jget "$JS" sni)
    SCY=$(jget "$JS" scy); FP=$(jget "$JS" fp); ALPN=$(jget "$JS" alpn)
    { [ -z "$ADD" ] || [ -z "$VPORT" ] || [ -z "$ID" ]; } && die "vmess: missing add/port/id"
    [ -z "$SCY" ] && SCY=auto; [ -z "$AID" ] && AID=0; [ -z "$NET" ] && NET=tcp
    [ -z "$SNI" ] && SNI="$HHDR"; [ -z "$SNI" ] && SNI="$ADD"
    TLSBLK=""; [ "$TLSV" = "tls" ] && TLSBLK=$(build_tls "$SNI" "" "$ALPN" "$FP" "" "")
    TRBLK=$(build_transport "$NET" "$PATHV" "$HHDR" "$PATHV")
    J="{ \"type\": \"vmess\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$ADD")\", \"server_port\": $VPORT, \"uuid\": \"$(jstr "$ID")\", \"security\": \"$(jstr "$SCY")\", \"alter_id\": $AID"
    [ -n "$TLSBLK" ] && J="$J, $TLSBLK"
    [ -n "$TRBLK" ] && J="$J, $TRBLK"
    emit "$J }"
    ;;
  trojan)
    [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USERINFO" ] && die "trojan: missing password/host/port"
    SNI=$(qp sni serverName peer); HHDR=$(qp host); NET=$(qp type net); PATHV=$(qp path)
    SVC=$(qp serviceName servicename); FP=$(qp fp fingerprint); ALPN=$(qp alpn)
    INS=$(qp allowInsecure insecure); { [ "$INS" = "1" ] || [ "$INS" = "true" ]; } && INS=1 || INS=
    [ -z "$NET" ] && NET=tcp; [ -z "$SNI" ] && SNI="$HHDR"; [ -z "$SNI" ] && SNI="$HOST"
    TLSBLK=$(build_tls "$SNI" "$INS" "$ALPN" "$FP" "" "")
    TRBLK=$(build_transport "$NET" "$PATHV" "$HHDR" "$SVC")
    J="{ \"type\": \"trojan\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$HOST")\", \"server_port\": $PORT, \"password\": \"$(jstr "$USERINFO")\", $TLSBLK"
    [ -n "$TRBLK" ] && J="$J, $TRBLK"
    emit "$J }"
    ;;
  ss)
    if [ -n "$USERINFO" ] && [ -n "$HOST" ]; then
      MP=$(b64dec "$USERINFO"); case "$MP" in *:*) : ;; *) MP="$USERINFO" ;; esac
      METHOD=${MP%%:*}; PASS=${MP#*:}
    else
      DEC=$(b64dec "$MAIN")
      U2=$(printf '%s' "$DEC" | sed -n 's/^\([^@]*\)@.*/\1/p')
      HP2=$(printf '%s' "$DEC" | sed 's/^[^@]*@//')
      METHOD=${U2%%:*}; PASS=${U2#*:}; HOST=${HP2%%:*}; PORT=${HP2##*:}
    fi
    { [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$METHOD" ]; } && die "ss: could not parse method/host/port"
    emit "{ \"type\": \"shadowsocks\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$HOST")\", \"server_port\": $PORT, \"method\": \"$(jstr "$METHOD")\", \"password\": \"$(jstr "$PASS")\" }"
    ;;
  hysteria2|hy2)
    [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USERINFO" ] && die "hysteria2: missing password/host/port"
    SNI=$(qp sni peer); [ -z "$SNI" ] && SNI="$HOST"
    INS=$(qp insecure allowInsecure); { [ "$INS" = "1" ] || [ "$INS" = "true" ]; } && INS=1 || INS=
    ALPN=$(qp alpn); OBFS=$(qp obfs); OBFSPW=$(qp obfs-password obfsParam)
    TLSBLK=$(build_tls "$SNI" "$INS" "$ALPN" "" "" "" quic)
    J="{ \"type\": \"hysteria2\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$HOST")\", \"server_port\": $PORT, \"password\": \"$(jstr "$USERINFO")\""
    [ "$OBFS" = "salamander" ] && [ -n "$OBFSPW" ] && J="$J, \"obfs\": { \"type\": \"salamander\", \"password\": \"$(jstr "$OBFSPW")\" }"
    J="$J, $TLSBLK"
    emit "$J }"
    ;;
  tuic)
    UUID=${USERINFO%%:*}; PASS=${USERINFO#*:}
    { [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$UUID" ]; } && die "tuic: missing uuid/host/port"
    SNI=$(qp sni peer); [ -z "$SNI" ] && SNI="$HOST"; ALPN=$(qp alpn)
    INS=$(qp insecure allowInsecure); { [ "$INS" = "1" ] || [ "$INS" = "true" ]; } && INS=1 || INS=
    CC=$(qp congestion_control congestion); [ -z "$CC" ] && CC=bbr
    TLSBLK=$(build_tls "$SNI" "$INS" "$ALPN" "" "" "" quic)
    emit "{ \"type\": \"tuic\", \"tag\": \"$(jstr "$TAG")\", \"server\": \"$(jstr "$HOST")\", \"server_port\": $PORT, \"uuid\": \"$(jstr "$UUID")\", \"password\": \"$(jstr "$PASS")\", \"congestion_control\": \"$(jstr "$CC")\", $TLSBLK }"
    ;;
  *) die "unsupported protocol: $SCHEME (supported: vless vmess trojan ss hysteria2 tuic)" ;;
esac
