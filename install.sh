#!/bin/sh
# ============================================================================
# Reality / Hysteria2 VPN for GL.iNet routers — CREDS-FREE, ARCH-UNIVERSAL.
#
# No binary and no credentials are bundled. At install time this script:
#   1. detects the router CPU arch and downloads the matching sing-box release
#      from github.com/SagerNet/sing-box (latest stable),
#   2. installs scripts to /etc/sing-box, an init.d service, cron jobs,
#   3. generates a valid DIRECT-only config (internet stays up with 0 servers).
# You add YOUR server afterwards with:  add-server.sh '<your share-link>'
# Run as root on the router.
# ============================================================================
set -e
D=$(cd "$(dirname "$0")" && pwd)
SBDIR=/etc/sing-box
say(){ echo "[reality-install] $*"; }
die(){ echo "[reality-install] ERROR: $*" >&2; exit 1; }

# ---- 0) clock sanity -------------------------------------------------------
# Routers lose the clock across reboot (no RTC battery) -> it defaults to the
# past, so HTTPS certs look "not yet valid" and every download fails. Best-effort
# NTP sync if the year is obviously wrong, so the sing-box download works.
if [ "$(date +%Y 2>/dev/null)" -lt 2025 ] 2>/dev/null; then
  say "router clock looks wrong ($(date)) -> syncing via NTP..."
  for NS in time.google.com pool.ntp.org 162.159.200.1; do
    ntpd -q -n -p "$NS" >/dev/null 2>&1 && break
  done
  say "clock now: $(date)"
fi

# ---- 1) detect arch -> sing-box release asset suffix -----------------------
# Prefer opkg's architecture (knows endianness for mips), fall back to uname -m.
OPKG_ARCH=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v '^all$\|^noarch$' | tail -1)
UM=$(uname -m)
say "uname -m=$UM  opkg-arch=${OPKG_ARCH:-none}"

ASSET=""
case "$OPKG_ARCH" in
  *aarch64*|*arm64*)           ASSET=linux-arm64 ;;
  *arm_cortex-a7*|*armv7*)     ASSET=linux-armv7 ;;
  *arm_*)                      ASSET=linux-armv7 ;;
  *mipsel*|*mips_24kc_*le*)    ASSET=linux-mipsle-softfloat ;;
  *mipsel_24kc*)               ASSET=linux-mipsle-softfloat ;;
  *mips_24kc*)                 ASSET=linux-mips-softfloat ;;
  *x86_64*|*amd64*)            ASSET=linux-amd64 ;;
esac
if [ -z "$ASSET" ]; then
  case "$UM" in
    aarch64|arm64)     ASSET=linux-arm64 ;;
    armv7*|armv6*|arm) ASSET=linux-armv7 ;;
    mips64el|mipsel|mipsle) ASSET=linux-mipsle-softfloat ;;
    mips64|mips)       ASSET=linux-mips-softfloat ;;   # big-endian (ath79/QCA)
    x86_64|amd64)      ASSET=linux-amd64 ;;
  esac
fi
[ -n "$ASSET" ] || die "unsupported arch (uname=$UM opkg=$OPKG_ARCH). Supported: arm64, armv7, mips/mipsle-softfloat, amd64."
say "selected sing-box asset arch: $ASSET"

# expected `file` signature to sanity-check the downloaded binary (endianness!)
case "$ASSET" in
  linux-arm64)            EXPECT="ARM aarch64" ;;
  linux-armv7)            EXPECT="ARM," ;;
  linux-mips-softfloat)   EXPECT="MIPS.*MSB" ;;   # big-endian
  linux-mipsle-softfloat) EXPECT="MIPS.*LSB" ;;   # little-endian
  linux-amd64)            EXPECT="x86-64" ;;
esac

# ---- 2) resolve latest stable tag + download -------------------------------
TAG=$(curl -4 -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$TAG" ] || die "could not fetch latest sing-box release tag (no internet / GitHub blocked)."
VER=${TAG#v}
URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-${ASSET}.tar.gz"
say "downloading sing-box $TAG ($ASSET)"
say "  $URL"
# download (~20MB tarball) + extracted sing-box (~60MB) need a roomy dir. /tmp is
# tmpfs (RAM) and too small on tiny routers (E750/AR300M) -> "No space left". Pick a
# writable mount with >=85MB free (microSD/USB/overlay); die clearly if none.
NEEDK=87040
WORKBASE=""
for c in /mnt/mmcblk0p1 /mnt/sda1 /mnt/sdcard /tmp/mountd/disk1_part1 /overlay; do
  [ -d "$c" ] || continue
  FK=$(df -k "$c" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$FK" ] && [ "$FK" -ge "$NEEDK" ] && [ -w "$c" ] && { WORKBASE="$c"; break; }
done
if [ -z "$WORKBASE" ]; then
  WORKBASE=$(df -k 2>/dev/null | awk 'NR>1 && $4>='"$NEEDK"' {print $6}' | while read m; do [ -w "$m" ] && { echo "$m"; break; }; done)
fi
[ -n "$WORKBASE" ] || die "need ~85MB free to unpack sing-box, none found. Insert a microSD card (it auto-mounts) and re-run."
say "work/extract dir: $WORKBASE ($(df -h "$WORKBASE" 2>/dev/null | awk 'NR==2{print $4}') free)"
SDHOME="$WORKBASE"
TMP=$(mktemp -d "$WORKBASE/sbdl.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
curl -4 -fL --retry 3 --connect-timeout 15 -o "$TMP/sb.tgz" "$URL" || die "download failed ($URL)"
tar xzf "$TMP/sb.tgz" -C "$TMP" || die "extract failed (corrupt download?)"
BIN=$(find "$TMP" -name sing-box -type f | head -1)
[ -n "$BIN" ] || die "sing-box binary not found in archive"
chmod +x "$BIN"

# ---- 3) verify the binary matches the expected arch/endianness -------------
# Verify it's an ELF (catches corrupt/HTML-error downloads) with ONLY the most basic
# busybox tools (head+grep). od/file/hexdump are often ABSENT on router busybox.
SIG=$(file -b "$BIN" 2>/dev/null || true)
head -c 4 "$BIN" 2>/dev/null | grep -q ELF || die "downloaded file is not an ELF binary - corrupt download? re-run to retry."
if [ -n "$SIG" ] && ! echo "$SIG" | grep -Eq "$EXPECT"; then
  die "binary ($SIG) does not match expected '$EXPECT' for $ASSET - wrong arch download."
fi
say "binary OK (ELF${SIG:+; $SIG})"

# ---- 4) flash-aware install of the binary ----------------------------------
# Try /usr/bin first; if rootfs is tight, fall back to microSD with a PATH symlink.
mkdir -p "$SBDIR/servers"
BINSZ=$(wc -c < "$BIN")
FREE=$(df -k /usr/bin 2>/dev/null | awk 'NR==2{print $4*1024}')
NEED=$((BINSZ + 2*1024*1024))
TARGET="$SBDIR/sing-box"
if [ -n "$FREE" ] && [ "$FREE" -lt "$NEED" ]; then
  say "rootfs low on space (${FREE}B free) -> installing binary to $SDHOME/sing-box/"
  mkdir -p "$SDHOME/sing-box"
  mv "$BIN" "$SDHOME/sing-box/sing-box" && chmod +x "$SDHOME/sing-box/sing-box"
  ln -sf "$SDHOME/sing-box/sing-box" "$SBDIR/sing-box"
  ln -sf "$SDHOME/sing-box/sing-box" /usr/bin/sing-box 2>/dev/null || true
else
  mv "$BIN" "$TARGET" && chmod +x "$TARGET"
  ln -sf "$TARGET" /usr/bin/sing-box 2>/dev/null || true
fi
VOUT=$("$SBDIR/sing-box" version 2>/dev/null | head -1)
[ -n "$VOUT" ] || die "sing-box did not run (wrong arch / corrupt). Re-run; if it persists, tell me."
say "installed: $VOUT"

# ---- 5) scripts ------------------------------------------------------------
for s in parse-link.sh rebuild.sh geo-refresh.sh postup.sh watchdog.sh ks-sync.sh \
         add-server.sh list-servers.sh del-server.sh; do
  cp "$D/$s" "$SBDIR/$s" && chmod +x "$SBDIR/$s"
done
# ship empty servers dir + the README/example for reference
cp -r "$D/servers/." "$SBDIR/servers/" 2>/dev/null || true
# Remove ONLY the shipped reference example (rebuild.sh globs servers/*.json, so the
# example must never become a live server). PRESERVE any srv-*.json the user already
# added -> re-running the installer to upgrade does NOT wipe their configured servers.
rm -f "$SBDIR/servers/server.example.json" 2>/dev/null || true

# ---- 6) sing-box service ---------------------------------------------------
cat > /etc/init.d/sing-box <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
  # Remove any stale tun left by a hard kill (SIGKILL) of a previous instance,
  # otherwise sing-box hits "TUNSETIFF: device or resource busy" and crash-loops.
  ip link del singtun0 2>/dev/null
  procd_open_instance
  procd_set_param command /etc/sing-box/sing-box run -c /etc/sing-box/reality_full.json
  procd_set_param respawn
  procd_close_instance
}
EOF
chmod +x /etc/init.d/sing-box
/etc/init.d/sing-box enable 2>/dev/null || true

# ---- 7) generate base config (0 servers -> direct, internet up) ------------
sh "$SBDIR/rebuild.sh" >/dev/null 2>&1 || true
# fresh install with no servers: leave VPN off until a server is added
[ -n "$(ls "$SBDIR"/servers/*.json 2>/dev/null)" ] || /etc/init.d/sing-box stop 2>/dev/null || true

# ---- 8) firewall: fw4/nftables vs fw3/iptables -----------------------------
# Detect by the live nft table (definitive — `[ -x /sbin/fw4 ]` is unreliable, and
# `iptables` is present on fw4 too as an nft-compat shim whose rules land in a
# SEPARATE table fw4 ignores -> LAN clients don't forward into the tun). On fw4 we
# add the LAN->tunnel forwarding directly into the `inet fw4` table via a
# hotplug-firewall hook so it survives reboots AND fw4 reloads (which flush it).
if nft list table inet fw4 >/dev/null 2>&1; then
  say "firewall: fw4/nftables detected -> installing nft forwarding hook"
  mkdir -p /etc/hotplug.d/firewall
  cat > /etc/hotplug.d/firewall/99-reality-fwd <<'EOF'
#!/bin/sh
# Re-apply Reality VPN LAN->tunnel forwarding into the fw4 nft table on every
# firewall reload (fw4 flushes custom rules on reload). Idempotent; harmless when
# the tunnel is down (rules just don't match until singtun0 appears).
command -v nft >/dev/null 2>&1 || exit 0
nft list table inet fw4 >/dev/null 2>&1 || exit 0
nft -a list chain inet fw4 forward 2>/dev/null | grep -q 'oifname "singtun0" accept' || nft insert rule inet fw4 forward oifname singtun0 accept 2>/dev/null
nft -a list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "singtun0" accept'  || nft insert rule inet fw4 forward iifname singtun0 accept 2>/dev/null
nft -a list chain inet fw4 srcnat  2>/dev/null | grep -q 'oifname "singtun0" masquerade' || nft add rule inet fw4 srcnat oifname singtun0 masquerade 2>/dev/null
exit 0
EOF
  chmod +x /etc/hotplug.d/firewall/99-reality-fwd
  grep -qxF /etc/hotplug.d/firewall/99-reality-fwd /etc/sysupgrade.conf 2>/dev/null || echo /etc/hotplug.d/firewall/99-reality-fwd >> /etc/sysupgrade.conf 2>/dev/null || true
  ACTION=reload sh /etc/hotplug.d/firewall/99-reality-fwd
  say "fw4 forwarding hook installed (survives reboot + firewall reloads)."
else
  say "firewall: iptables/fw3 path active (postup.sh installs FORWARD+MASQUERADE rules)."
fi

# ---- 9) cron: LAN forwarding re-apply, internet watchdog, geo cache --------
CR=/etc/crontabs/root; touch "$CR"
grep -q 'sing-box/postup.sh'   "$CR" || echo '*/2 * * * * /bin/sh /etc/sing-box/postup.sh'      >> "$CR"
grep -q 'sing-box/watchdog.sh' "$CR" || echo '*   * * * * /bin/sh /etc/sing-box/watchdog.sh'    >> "$CR"
grep -q 'sing-box/geo-refresh' "$CR" || echo '*/5 * * * * /bin/sh /etc/sing-box/geo-refresh.sh' >> "$CR"
grep -q 'sing-box/ks-sync.sh'  "$CR" || echo '*   * * * * /bin/sh /etc/sing-box/ks-sync.sh'     >> "$CR"
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

# SAFETY: fresh install -> killswitch OFF by default (only set the flag if GL's rule
# exists; never create a partial rule). With ks-sync's VPN-gate + postup fail-open,
# a down/unconfigured VPN can never strand the LAN without internet.
uci -q get route_policy.@rule[0].killswitch >/dev/null 2>&1 && \
  { uci -q set route_policy.@rule[0].killswitch='0'; uci -q commit route_policy; }
sh "$SBDIR/ks-sync.sh" 2>/dev/null || true

# ---- 9b) web control panel (:8088, browser UI, firmware-agnostic) ----------
# uhttpd + POSIX-sh CGI: add/manage servers from a browser, no terminal needed.
if [ -f "$D/panel/index.html" ] && [ -f "$D/panel/api" ] && [ -f "$D/panel/vpn-panel.init" ]; then
  # Panel needs uhttpd + openssl. If missing, install them (router is online during install).
  if ! command -v uhttpd >/dev/null 2>&1; then
    say "uhttpd missing -> installing via opkg..."; opkg update >/dev/null 2>&1; opkg install uhttpd >/dev/null 2>&1
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    say "openssl missing -> installing via opkg..."; opkg update >/dev/null 2>&1; opkg install openssl-util >/dev/null 2>&1
  fi
  mkdir -p /www-vpn/cgi-bin
  cp "$D/panel/index.html" /www-vpn/index.html
  cp "$D/panel/api" /www-vpn/cgi-bin/api && chmod +x /www-vpn/cgi-bin/api
  cp "$D/panel/vpn-panel.init" /etc/init.d/vpn-panel && chmod +x /etc/init.d/vpn-panel
  /etc/init.d/vpn-panel enable 2>/dev/null || true
  /etc/init.d/vpn-panel restart 2>/dev/null || /etc/init.d/vpn-panel start 2>/dev/null || true
  sleep 1
  # Verify the panel is actually serving on :8088 (honest report, not just "deployed").
  PC=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8088/ 2>/dev/null)
  case "$PC" in
    200|401|403) say "web panel LIVE (http $PC): http://<router-LAN-ip>:8088  (log in with the router admin password)" ;;
    *) say "WARN: web panel not serving on :8088 (got '$PC'). Check: command -v uhttpd; logread | grep uhttpd. The native tab / add-server.sh still work." ;;
  esac
else
  say "NOTE: panel/ files not bundled -> skipping web panel (terminal add-server.sh still works)."
fi

# ---- 9c) SDK4 native menu tab (GL fw 4.x only — ADDITIVE to the :8088 panel) -
# On GL fw 4.x the router UI is the SDK4 (oui-httpd + Vue views) stack. If those
# dirs exist we drop in a native "Reality" tab under the VPN menu. On fw 3.x the
# dirs are absent -> skip silently (the :8088 panel already covers those routers).
SDK4_FILES_OK=0
[ -f "$D/sdk4-tab/reality.menu.json" ] && [ -f "$D/sdk4-tab/gl-sdk4-ui-reality.common.js" ] && \
  [ -f "$D/sdk4-tab/reality.oui.lua" ] && [ -f "$D/sdk4-tab/reality.validator.lua" ] && SDK4_FILES_OK=1
if [ -d /usr/lib/oui-httpd/rpc ] && [ -d /usr/share/oui/menu.d ] && [ -d /www/views ]; then
  if [ "$SDK4_FILES_OK" = 1 ]; then
    say "GL SDK4 detected -> installing native VPN->Reality menu tab"
    mkdir -p /usr/share/gl-validator.d
    cp "$D/sdk4-tab/reality.menu.json"                  /usr/share/oui/menu.d/reality.json
    # Deploy the UNCOMPRESSED view (the SPA loads it via axios.get('/views/...js'))
    # and generate a .gz sibling for nginx `gzip_static`. If this router's nginx
    # lacks gzip_static, the plain .js is served anyway -> no /#/login bounce.
    cp "$D/sdk4-tab/gl-sdk4-ui-reality.common.js"       /www/views/gl-sdk4-ui-reality.common.js
    gzip -c "$D/sdk4-tab/gl-sdk4-ui-reality.common.js" > /www/views/gl-sdk4-ui-reality.common.js.gz 2>/dev/null
    cp "$D/sdk4-tab/reality.oui.lua"                    /usr/lib/oui-httpd/rpc/reality
    cp "$D/sdk4-tab/reality.validator.lua"              /usr/share/gl-validator.d/reality.lua
    # CRITICAL reload sequence (order matters — get this exact or you lock the
    # user out of the panel): a FULL nginx restart is required to drop OpenResty's
    # cached lua so the new `reality` rpc handler loads (a plain reload won't);
    # BUT a full nginx restart breaks GL's post-login session websocket bridge,
    # so we MUST immediately rebuild it with gl-ngx-session. Do BOTH, in order.
    /etc/init.d/nginx restart 2>/dev/null; /etc/init.d/gl-ngx-session restart 2>/dev/null
    # survive firmware upgrades
    for p in /usr/share/oui/menu.d/reality.json /www/views/gl-sdk4-ui-reality.common.js.gz \
             /www/views/gl-sdk4-ui-reality.common.js \
             /usr/lib/oui-httpd/rpc/reality /usr/share/gl-validator.d/reality.lua; do
      grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf 2>/dev/null || true
    done
    # self-diagnostic (prints to the install log so we can confirm the tab will load,
    # or pinpoint a /#/login bounce: view 404 = serving issue, empty rpc = handler issue,
    # gl-ngx-session ABSENT = session-bridge issue).
    VJS=$(curl -s -o /dev/null -w '%{http_code}/%{size_download}b' --max-time 5 http://127.0.0.1/views/gl-sdk4-ui-reality.common.js 2>/dev/null)
    VGZ=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Accept-Encoding: gzip' http://127.0.0.1/views/gl-sdk4-ui-reality.common.js 2>/dev/null)
    RPCJ=$(curl -s --max-time 5 -X POST http://127.0.0.1/rpc -H 'glinet: 1' -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["","reality","get_status",{}]}' 2>/dev/null | head -c 50)
    GLS=$([ -x /etc/init.d/gl-ngx-session ] && echo present || echo ABSENT)
    say "diag: view.js=$VJS gz_code=$VGZ gl-ngx-session=$GLS rpc=${RPCJ:-EMPTY}"
    say "native Reality tab deployed: open the router UI -> VPN -> Reality"
  else
    say "NOTE: SDK4 router detected but sdk4-tab/ files not bundled -> skipping native tab (the :8088 panel still works)."
  fi
else
  say "NOTE: not a GL SDK4 (fw 4.x) router -> skipping native menu tab; the :8088 web panel covers this firmware."
fi

# ---- 10) survive firmware updates ------------------------------------------
for p in /etc/sing-box /etc/init.d/sing-box /www-vpn /etc/init.d/vpn-panel; do
  grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf 2>/dev/null || true
done

say "DONE."
say "Add YOUR server:   sh $SBDIR/add-server.sh 'vless://...security=reality...#myserver'"
say "List / remove:     sh $SBDIR/list-servers.sh   |   sh $SBDIR/del-server.sh <tag>"
