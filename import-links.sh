#!/bin/sh
# import-links.sh — bulk-import many servers at once (Shadowrocket-style).
#
# Reads the payload from stdin. The payload may be ANY of:
#   - an http(s):// subscription URL   -> fetched, then treated as below
#   - a base64 subscription blob       -> decoded to a link-per-line list
#   - plain text, one share-link per line (vless/vmess/trojan/ss/hysteria2/tuic)
#   - a single share-link              -> imports just that one
#
# Each link is parsed with parse-link.sh and written to servers/<tag>.json.
# Rebuild runs ONCE at the end (fast path). If that rebuild fails the schema
# check, we fall back to adding the links one-by-one so the VALID ones still
# land and only the bad ones are skipped.
#
# Prints a JSON summary: {"ok":true,"added":N,"failed":M,"tags":[...]}
SBDIR=${SBDIR:-/etc/sing-box}
SRV="$SBDIR/servers"
DIR=$(cd "$(dirname "$0")" && pwd)
PARSE="$SBDIR/parse-link.sh"; [ -x "$PARSE" ] || PARSE="$DIR/parse-link.sh"
REBUILD="$SBDIR/rebuild.sh"; [ -f "$REBUILD" ] || REBUILD="$DIR/rebuild.sh"
mkdir -p "$SRV"

b64dec(){ # tolerant base64 (url-safe + missing pad). prefer base64, fall back to openssl
  s=$(printf '%s' "$1" | tr '_-' '/+' | tr -d '\n\r \t')
  case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
  if command -v base64 >/dev/null 2>&1; then printf '%s' "$s" | base64 -d 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then printf '%s' "$s" | openssl base64 -d -A 2>/dev/null
  fi
}
urldec(){ printf '%s' "$1" | awk '
  BEGIN{ for(i=0;i<16;i++){ x=sprintf("%x",i); H[x]=i; H[toupper(x)]=i } }
  { gsub(/\+/," "); r=""; n=length($0); i=1;
    while(i<=n){ c=substr($0,i,1);
      if(c=="%" && i+2<=n){ a=substr($0,i+1,1); b=substr($0,i+2,1);
        if((a in H)&&(b in H)){ r=r sprintf("%c",H[a]*16+H[b]); i+=3; continue } }
      r=r c; i++ } print r }'; }

RAW=$(cat)
# trim leading/trailing whitespace
RAW=$(printf '%s' "$RAW" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -z "$RAW" ] && { echo '{"ok":false,"added":0,"failed":0,"msg":"empty input"}'; exit 0; }

# 1) subscription URL -> fetch
case "$RAW" in
  http://*|https://*)
    [ "$(printf '%s' "$RAW" | wc -l)" -eq 0 ] && {
      FETCH=$(curl -fsSL --max-time 20 "$RAW" 2>/dev/null)
      [ -n "$FETCH" ] && RAW=$(printf '%s' "$FETCH" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    } ;;
esac

# 2) base64 blob (no scheme:// anywhere) -> decode to a link list
case "$RAW" in
  *://*) : ;;
  *) DEC=$(b64dec "$RAW"); printf '%s' "$DEC" | grep -q '://' && RAW="$DEC" ;;
esac

# 3) iterate non-empty lines that carry a scheme
ADDED=0; FAILED=0; TAGS=""; FAILED_FILES=""
add_one(){ # add_one <link>  -> writes file, echoes tag on success (no rebuild)
  _l="$1"
  _nm=$(printf '%s' "$_l" | sed -n 's/^[^#]*#//p'); _nm=$(urldec "$_nm")
  _base=$(printf '%s' "$_nm" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//')
  [ -z "$_base" ] && _base="srv-$(date +%s)"
  case "$_base" in srv-*) : ;; *) _base="srv-$_base" ;; esac
  _tag="$_base"; _i=1
  while [ -e "$SRV/$_tag.json" ]; do _tag="${_base}-$_i"; _i=$((_i+1)); done
  _out=$("$PARSE" "$_l" "$_tag" 2>/dev/null)
  [ -z "$_out" ] && return 1
  printf '%s' "$_out" > "$SRV/$_tag.json"
  printf '%s' "$_tag"; return 0
}

NEWTAGS=""
OLDIFS=$IFS; IFS='
'
for line in $RAW; do
  l=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -z "$l" ] && continue
  case "$l" in *://*) : ;; *) continue ;; esac
  t=$(add_one "$l")
  if [ -n "$t" ]; then ADDED=$((ADDED+1)); TAGS="$TAGS,\"$t\""; NEWTAGS="$NEWTAGS $t"
  else FAILED=$((FAILED+1)); fi
done
IFS=$OLDIFS

[ "$ADDED" -eq 0 ] && { echo "{\"ok\":false,\"added\":0,\"failed\":$FAILED,\"msg\":\"no valid links\"}"; exit 0; }

# fast path: one rebuild for the whole batch
R=$(sh "$REBUILD" 2>/dev/null | head -1)
if [ "$R" = "OK" ]; then
  printf '{"ok":true,"added":%s,"failed":%s,"tags":[%s]}\n' "$ADDED" "$FAILED" "${TAGS#,}"
  exit 0
fi

# slow path: a parsed link was schema-rejected by sing-box. Remove the batch and
# re-add one at a time so the valid ones survive and only the bad ones drop.
for t in $NEWTAGS; do rm -f "$SRV/$t.json"; done
ADDED=0; FAILED=0; TAGS=""
IFS='
'
for line in $RAW; do
  l=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -z "$l" ] && continue
  case "$l" in *://*) : ;; *) continue ;; esac
  t=$(add_one "$l") || { FAILED=$((FAILED+1)); continue; }
  RR=$(sh "$REBUILD" 2>/dev/null | head -1)
  if [ "$RR" = "OK" ]; then ADDED=$((ADDED+1)); TAGS="$TAGS,\"$t\""
  else rm -f "$SRV/$t.json"; FAILED=$((FAILED+1)); fi
done
IFS=$OLDIFS
sh "$REBUILD" >/dev/null 2>&1
printf '{"ok":true,"added":%s,"failed":%s,"tags":[%s]}\n' "$ADDED" "$FAILED" "${TAGS#,}"
