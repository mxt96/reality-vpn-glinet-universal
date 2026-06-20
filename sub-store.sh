#!/bin/sh
# sub-store.sh — saved subscriptions with auto-update (Happ-style).
#
# Happ re-pulls every subscription on app open and keeps the server list in sync.
# A router has no "app open", so we STORE each subscription URL and let the user
# (panel button) or cron (periodic) re-pull it: new servers appear, vanished ones
# are removed, untouched ones keep their tag (so the active selection survives).
#
# Layout under $SBDIR/subs/:
#   <id>.url     first line = display name, second line = the http(s) URL
#   <id>.tags    newline list of server tags this subscription currently owns
#   <id>.upd     last successful refresh, epoch seconds
# Each server this sub creates is a normal $SBDIR/servers/<tag>.json (built by
# import-links.sh) — nothing special, so the rest of the stack treats them like
# any manually-added server.
#
# Commands:
#   add <url> [name]    save + initial pull          -> {"ok":true,"id":..,"added":N}
#   list                                              -> {"subs":[{id,name,url,count,updated}]}
#   del <id>            remove sub + the servers it owns
#   refresh [<id>|all]  re-pull; add new / drop gone -> {"ok":true,"subs":K,"added":N,"removed":M}
#
# Busybox/ash safe. Reuses import-links.sh for the fetch/decode/parse/rebuild.
SBDIR=${SBDIR:-/etc/sing-box}
SRV="$SBDIR/servers"
SUBS="$SBDIR/subs"
DIR=$(cd "$(dirname "$0")" && pwd)
IMPORT="$SBDIR/import-links.sh"; [ -x "$IMPORT" ] || IMPORT="$DIR/import-links.sh"
REBUILD="$SBDIR/rebuild.sh"; [ -f "$REBUILD" ] || REBUILD="$DIR/rebuild.sh"
mkdir -p "$SRV" "$SUBS"

now(){ date +%s 2>/dev/null || echo 0; }
jstr(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
UA='v2rayNG/1.8.19'
b64d(){ s=$(printf '%s' "$1" | tr '_-' '/+' | tr -d '\n\r '); case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
  if command -v base64 >/dev/null 2>&1; then printf '%s' "$s" | base64 -d 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then printf '%s' "$s" | openssl base64 -d -A 2>/dev/null; fi; }
# capture Happ-style subscription metadata from response headers into <id>.meta
# (profile-title = name, subscription-userinfo = traffic/expiry, support-url = link)
grab_meta(){
  _gid="$1"; _gurl="$2"
  _h=$(curl -fsSL -A "$UA" --max-time 15 -D - -o /dev/null "$_gurl" 2>/dev/null)
  [ -z "$_h" ] && return 0
  _tt=$(printf '%s' "$_h" | sed -n 's/^[Pp]rofile-[Tt]itle:[[:space:]]*//p' | tr -d '\r' | head -1)
  case "$_tt" in base64:*) _tt=$(b64d "${_tt#base64:}") ;; esac
  _ui=$(printf '%s' "$_h" | sed -n 's/^[Ss]ubscription-[Uu]serinfo:[[:space:]]*//p' | tr -d '\r' | head -1)
  _su=$(printf '%s' "$_h" | sed -n 's/^[Ss]upport-[Uu]rl:[[:space:]]*//p' | tr -d '\r' | head -1)
  {
    printf 'title=%s\n' "$_tt"
    printf 'userinfo=%s\n' "$_ui"
    printf 'support=%s\n' "$_su"
  } > "$SUBS/$_gid.meta"
}
# slug: lower, keep alnum._-, collapse the rest to '-'
slug(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-40; }

# pull <id> <url> : delete the sub's old servers, import fresh, record new tags.
# Echoes "added removed" counts. Does NOT rebuild per-server — import-links does ONE
# rebuild at the end, which is enough (deletes are just file removals before it).
pull(){
  _id="$1"; _url="$2"; _removed=0
  if [ -f "$SUBS/$_id.tags" ]; then
    while IFS= read -r _t; do
      [ -z "$_t" ] && continue
      [ -f "$SRV/$_t.json" ] && { rm -f "$SRV/$_t.json"; _removed=$((_removed+1)); }
    done < "$SUBS/$_id.tags"
  fi
  # import-links prints {"ok":..,"added":N,..,"tags":["a","b"]}
  _out=$(printf '%s' "$_url" | env SBDIR="$SBDIR" sh "$IMPORT" 2>/dev/null)
  _added=$(printf '%s' "$_out" | sed -n 's/.*"added":\([0-9]*\).*/\1/p')
  [ -z "$_added" ] && _added=0
  # extract tags array -> newline list
  printf '%s' "$_out" | sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | sed 's/^"//; s/"$//' | grep . > "$SUBS/$_id.tags" 2>/dev/null
  now > "$SUBS/$_id.upd"
  grab_meta "$_id" "$_url"
  printf '%s %s' "$_added" "$_removed"
}

CMD="$1"; shift 2>/dev/null

case "$CMD" in
  add)
    URL="$1"; NAME="$2"
    case "$URL" in http://*|https://*) : ;; *) echo '{"ok":false,"msg":"need an http(s) subscription URL"}'; exit 0 ;; esac
    [ -z "$NAME" ] && NAME=$(printf '%s' "$URL" | sed -n 's#^https\?://\([^/]*\).*#\1#p')
    ID=$(slug "$NAME"); [ -z "$ID" ] && ID="sub-$(now)"
    # avoid clobbering an existing different sub
    if [ -f "$SUBS/$ID.url" ] && [ "$(sed -n 2p "$SUBS/$ID.url")" != "$URL" ]; then
      _i=1; while [ -f "$SUBS/$ID-$_i.url" ]; do _i=$((_i+1)); done; ID="$ID-$_i"
    fi
    printf '%s\n%s\n' "$NAME" "$URL" > "$SUBS/$ID.url"
    set -- $(pull "$ID" "$URL"); ADDED="$1"
    if [ "${ADDED:-0}" -eq 0 ]; then
      # nothing imported -> don't keep a dead sub on disk; report the truth
      rm -f "$SUBS/$ID.url" "$SUBS/$ID.tags" "$SUBS/$ID.upd"
      printf '{"ok":false,"id":"%s","added":0,"msg":"subscription returned no valid servers"}\n' "$(jstr "$ID")"
    else
      printf '{"ok":true,"id":"%s","name":"%s","added":%s}\n' "$(jstr "$ID")" "$(jstr "$NAME")" "$ADDED"
    fi
    ;;

  list)
    OUT=""
    for f in "$SUBS"/*.url; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .url)
      nm=$(sed -n 1p "$f"); url=$(sed -n 2p "$f")
      cnt=0; [ -f "$SUBS/$id.tags" ] && cnt=$(grep -c . "$SUBS/$id.tags" 2>/dev/null)
      upd=0; [ -f "$SUBS/$id.upd" ] && upd=$(cat "$SUBS/$id.upd" 2>/dev/null)
      title=""; userinfo=""; support=""
      if [ -f "$SUBS/$id.meta" ]; then
        title=$(sed -n 's/^title=//p' "$SUBS/$id.meta" | head -1)
        userinfo=$(sed -n 's/^userinfo=//p' "$SUBS/$id.meta" | head -1)
        support=$(sed -n 's/^support=//p' "$SUBS/$id.meta" | head -1)
      fi
      # subscription-userinfo: "upload=..; download=..; total=..; expire=epoch"
      used=0; total=0; expire=0
      [ -n "$userinfo" ] && {
        dl=$(printf '%s' "$userinfo" | sed -n 's/.*download=\([0-9]*\).*/\1/p')
        ul=$(printf '%s' "$userinfo" | sed -n 's/.*upload=\([0-9]*\).*/\1/p')
        total=$(printf '%s' "$userinfo" | sed -n 's/.*total=\([0-9]*\).*/\1/p')
        expire=$(printf '%s' "$userinfo" | sed -n 's/.*expire=\([0-9]*\).*/\1/p')
        used=$(( ${dl:-0} + ${ul:-0} ))
      }
      OUT="$OUT,{\"id\":\"$(jstr "$id")\",\"name\":\"$(jstr "${title:-$nm}")\",\"url\":\"$(jstr "$url")\",\"count\":${cnt:-0},\"updated\":${upd:-0},\"used\":${used:-0},\"total\":${total:-0},\"expire\":${expire:-0},\"support\":\"$(jstr "$support")\"}"
    done
    printf '{"subs":[%s]}\n' "${OUT#,}"
    ;;

  del)
    ID="$1"
    case "$ID" in *[!A-Za-z0-9._-]*|"") echo '{"ok":false,"msg":"bad id"}'; exit 0 ;; esac
    [ -f "$SUBS/$ID.url" ] || { echo '{"ok":false,"msg":"no such subscription"}'; exit 0; }
    RM=0
    if [ -f "$SUBS/$ID.tags" ]; then
      while IFS= read -r t; do [ -z "$t" ] && continue
        [ -f "$SRV/$t.json" ] && { rm -f "$SRV/$t.json"; RM=$((RM+1)); }
      done < "$SUBS/$ID.tags"
    fi
    rm -f "$SUBS/$ID.url" "$SUBS/$ID.tags" "$SUBS/$ID.upd"
    sh "$REBUILD" >/dev/null 2>&1
    printf '{"ok":true,"removed":%s}\n' "$RM"
    ;;

  refresh)
    WHICH="${1:-all}"
    TADD=0; TRM=0; K=0
    for f in "$SUBS"/*.url; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .url)
      [ "$WHICH" = "all" ] || [ "$WHICH" = "$id" ] || continue
      url=$(sed -n 2p "$f"); [ -z "$url" ] && continue
      set -- $(pull "$id" "$url")
      TADD=$((TADD + ${1:-0})); TRM=$((TRM + ${2:-0})); K=$((K+1))
    done
    [ "$K" -eq 0 ] && { echo '{"ok":false,"subs":0,"msg":"no subscriptions to refresh"}'; exit 0; }
    printf '{"ok":true,"subs":%s,"added":%s,"removed":%s}\n' "$K" "$TADD" "$TRM"
    ;;

  *)
    echo '{"ok":false,"msg":"usage: sub-store.sh add|list|del|refresh"}'
    ;;
esac
