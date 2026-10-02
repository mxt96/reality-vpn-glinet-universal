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
mkdir -p "$SUBS"

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

# Stage the complete candidate set; a failed fetch or check never touches live files.
pull() (
  _id="$1"; _url="$2"; _removed=0; _committed=0; _metadata=0
  _stage=$(mktemp -d "$SBDIR/.sub-stage.XXXXXX") || return 1
  cleanup(){
    if [ "$_committed" = 0 ] && [ -d "$_stage/previous" ]; then
      if [ -d "$SRV" ] && ! mv "$SRV" "$_stage/rejected"; then return 1; fi
      mv "$_stage/previous" "$SRV" || return 1
      sh "$REBUILD" >/dev/null 2>&1
    fi
    if [ "$_committed" = 0 ] && [ "$_metadata" = 1 ]; then
      for _ext in tags upd url; do
        if [ -f "$_stage/old.$_ext" ]; then
          mv "$_stage/old.$_ext" "$SUBS/$_id.$_ext" || return 1
        else
          rm -f "$SUBS/$_id.$_ext" || return 1
        fi
      done
    fi
    find "$_stage" -depth -delete
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  mkdir "$_stage/servers" || return 1
  for _f in "$SRV/"*.json; do
    [ -f "$_f" ] || continue
    cp -p "$_f" "$_stage/servers/" || return 1
  done
  if [ -f "$SBDIR/favorites" ]; then cp "$SBDIR/favorites" "$_stage/favorites" || return 1; fi
  if [ -x "$SBDIR/sing-box" ]; then ln -s "$SBDIR/sing-box" "$_stage/sing-box" || return 1; fi
  if [ -f "$SUBS/$_id.tags" ]; then
    while IFS= read -r _t; do
      case "$_t" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
      if [ -f "$_stage/servers/$_t.json" ]; then
        rm -f "$_stage/servers/$_t.json" || return 1
        _removed=$((_removed+1))
      fi
    done < "$SUBS/$_id.tags"
  fi
  cp "$REBUILD" "$_stage/rebuild.sh" || return 1
  _out=$(printf '%s' "$_url" | env SBDIR="$_stage" REBUILD_CHECK_ONLY=1 sh "$IMPORT" 2>/dev/null) || return 1
  _added=$(printf '%s' "$_out" | sed -n 's/.*"added":\([0-9]*\).*/\1/p')
  if ! printf '%s' "$_out" | grep -q '"ok":true' || [ "${_added:-0}" -eq 0 ]; then return 1; fi
  printf '%s' "$_out" | sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | sed 's/^"//; s/"$//' | grep . > "$_stage/tags" || return 1
  [ "$(wc -l < "$_stage/tags" | tr -d ' ')" -eq "$_added" ] || return 1
  while IFS= read -r _t; do
    case "$_t" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ -s "$_stage/servers/$_t.json" ] || return 1
  done < "$_stage/tags"
  now > "$_stage/upd" || return 1
  if [ "$#" -ge 3 ]; then
    printf '%s\n%s\n' "$3" "$_url" > "$_stage/url" || return 1
  elif [ -f "$SUBS/$_id.url" ]; then
    cp "$SUBS/$_id.url" "$_stage/url" || return 1
  fi
  for _ext in tags upd url; do
    if [ -f "$SUBS/$_id.$_ext" ]; then cp "$SUBS/$_id.$_ext" "$_stage/old.$_ext" || return 1; fi
  done
  mv "$SRV" "$_stage/previous" || return 1
  mv "$_stage/servers" "$SRV" || return 1
  _result=$(sh "$REBUILD" 2>/dev/null | head -1)
  [ "$_result" = OK ] || return 1
  _metadata=1
  mv "$_stage/tags" "$SUBS/$_id.tags" || return 1
  mv "$_stage/upd" "$SUBS/$_id.upd" || return 1
  if [ -f "$_stage/url" ]; then mv "$_stage/url" "$SUBS/$_id.url" || return 1; fi
  _committed=1
  grab_meta "$_id" "$_url"
  printf '%s %s' "$_added" "$_removed"
)

CMD="$1"; shift 2>/dev/null

case "$CMD" in
  add|del|refresh)
    if ! mkdir "$SBDIR/.servers.lock" 2>/dev/null; then echo '{"ok":false,"msg":"Server update already running"}'; exit 0; fi
    trap 'rmdir "$SBDIR/.servers.lock" 2>/dev/null' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p "$SRV" || exit 1
    ;;
esac

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
    if COUNTS=$(pull "$ID" "$URL" "$NAME"); then
      set -- $COUNTS; ADDED="$1"
      printf '{"ok":true,"id":"%s","name":"%s","added":%s}\n' "$(jstr "$ID")" "$(jstr "$NAME")" "$ADDED"
    else
      printf '{"ok":false,"id":"%s","added":0,"msg":"Subscription update failed; existing servers preserved"}\n' "$(jstr "$ID")"
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
    TADD=0; TRM=0; K=0; FAILED=0
    for f in "$SUBS"/*.url; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .url)
      [ "$WHICH" = "all" ] || [ "$WHICH" = "$id" ] || continue
      url=$(sed -n 2p "$f"); [ -z "$url" ] && continue
      K=$((K+1))
      if COUNTS=$(pull "$id" "$url"); then
        set -- $COUNTS
        TADD=$((TADD + ${1:-0})); TRM=$((TRM + ${2:-0}))
      else
        FAILED=$((FAILED+1))
      fi
    done
    [ "$K" -eq 0 ] && { echo '{"ok":false,"subs":0,"msg":"no subscriptions to refresh"}'; exit 0; }
    OK=true; [ "$FAILED" -eq 0 ] || OK=false
    printf '{"ok":%s,"subs":%s,"added":%s,"removed":%s,"failed":%s}\n' "$OK" "$K" "$TADD" "$TRM" "$FAILED"
    ;;

  *)
    echo '{"ok":false,"msg":"usage: sub-store.sh add|list|del|refresh"}'
    ;;
esac
