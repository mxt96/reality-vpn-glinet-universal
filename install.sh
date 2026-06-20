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
# Probe `sing-box version`. NOTE: do NOT drop_caches here. On a 128MB router (E750) the
# ~58MB Go binary needs its code pages resident to run; dropping the page cache right
# before exec forces a cold ~58MB fault under the memory pressure left by the just-
# finished download+unpack -> OOM kills it ("Terminated"). (A v1.2.3 drop_caches attempt
# made this WORSE — the binary runs fine warm/at idle, dies on a forced cold load.) So:
# just retry a few times with a short settle; the reuse probe runs at calm memory and
# succeeds, and the post-download probe is treated as non-fatal for static arches below.
sb_version() {
  for _t in 1 2 3; do
    _v=$("$SBDIR/sing-box" version 2>/dev/null | head -1)
    [ -n "$_v" ] && { echo "$_v"; return 0; }
    sync 2>/dev/null; sleep 1
  done
  return 1
}
# Re-run / upgrade friendliness: if sing-box is already installed and RUNS, reuse it
# and SKIP the ~85MB download+unpack. On tiny routers (E750 has ~28MB free after the
# first install) the space check below would otherwise abort a re-run -> the UI/panel
# never get installed. To force a fresh sing-box: rm "$SBDIR/sing-box" then re-run.
VOUT=""
EXIST=$(sb_version || true)
if [ -n "$EXIST" ]; then
  VOUT="$EXIST"; mkdir -p "$SBDIR/servers"
  say "sing-box already installed ($EXIST) -> reusing, skipping download"
fi
if [ -z "$VOUT" ]; then
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
mkdir -p "$SBDIR/servers"

# ---- 3+4) download + verify + install (musl-aware) -------------------------
# OpenWrt is musl. SagerNet's DEFAULT arm64/amd64 asset is glibc-dynamic and will
# NOT run on musl ("ld-linux not found"); they also publish an explicit `-musl`
# (static) asset. So prefer `${ASSET}-musl`, fall back to the plain `${ASSET}`
# (mips/armv7 have no -musl suffix and the plain build is already musl-static).
# Verify each candidate is an ELF of the right arch AND that it actually RUNS.
# Only arm64/amd64 ship a separate `-musl` (static) asset; the default there is
# glibc-dynamic and won't run on OpenWrt's musl, so try `-musl` first for them.
# mips/mipsle/armv7 have NO `-musl` suffix (the plain build is already musl-static),
# so trying `-musl` there just 404s — try plain only. (PLAIN = the empty suffix.)
case "$ASSET" in
  linux-arm64|linux-amd64) SUFFIXES="-musl PLAIN" ;;
  *)                       SUFFIXES="PLAIN" ;;
esac
VOUT=""
for SUF in $SUFFIXES; do
  [ "$SUF" = PLAIN ] && SUF=""
  URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-${ASSET}${SUF}.tar.gz"
  say "trying sing-box $TAG (${ASSET}${SUF})"
  TMP=$(mktemp -d "$SDHOME/sbdl.XXXXXX") || continue
  if ! curl -4 -fL --retry 2 --connect-timeout 15 -o "$TMP/sb.tgz" "$URL"; then rm -rf "$TMP"; continue; fi
  if ! tar xzf "$TMP/sb.tgz" -C "$TMP" 2>/dev/null; then rm -rf "$TMP"; continue; fi
  BIN=$(find "$TMP" -name sing-box -type f | head -1)
  [ -n "$BIN" ] || { rm -rf "$TMP"; continue; }
  chmod +x "$BIN"
  head -c 4 "$BIN" 2>/dev/null | grep -q ELF || { rm -rf "$TMP"; continue; }
  SIG=$(file -b "$BIN" 2>/dev/null || true)
  if [ -n "$SIG" ] && ! echo "$SIG" | grep -Eq "$EXPECT"; then rm -rf "$TMP"; continue; fi
  # The executable MUST live on a kernel filesystem. Exec from a FUSE/exFAT/vfat
  # removable card is UNRELIABLE: code pages re-faulted from a FUSE backend get the
  # process killed ("Terminated") — especially after a cache drop — even with plenty
  # of free RAM. (This bit a GL-E750 hard: 58MB binary on an exFAT card ran once warm
  # but died on every cold exec.) So install to internal flash ($SBDIR, on the overlay)
  # whenever it fits; only fall back to the work dir if THAT dir is a real, exec-safe fs.
  BINSZ=$(wc -c < "$BIN"); NEED=$((BINSZ + 1024*1024))
  SBFREE=$(df -k "$SBDIR" 2>/dev/null | awk 'NR==2{print $4*1024}')
  fs_is_exec_safe() {   # false (1) if $1's mount is a FUSE/exFAT/vfat/ntfs card
    _mp=$(df "$1" 2>/dev/null | awk 'NR==2{print $NF}')
    _ty=$(awk -v m="$_mp" '$2==m{t=$3} END{print t}' /proc/mounts 2>/dev/null)
    case "$_ty" in fuseblk|fuse.*|exfat|vfat|msdos|ntfs*) return 1 ;; *) return 0 ;; esac
  }
  if [ -n "$SBFREE" ] && [ "$SBFREE" -ge "$NEED" ]; then
    mv "$BIN" "$SBDIR/sing-box" && chmod +x "$SBDIR/sing-box"
    ln -sf "$SBDIR/sing-box" /usr/bin/sing-box 2>/dev/null || true
    say "installed binary to internal flash ($SBDIR)"
  elif fs_is_exec_safe "$SDHOME"; then
    mkdir -p "$SDHOME/sing-box"
    mv "$BIN" "$SDHOME/sing-box/sing-box" && chmod +x "$SDHOME/sing-box/sing-box"
    ln -sf "$SDHOME/sing-box/sing-box" "$SBDIR/sing-box"
    ln -sf "$SDHOME/sing-box/sing-box" /usr/bin/sing-box 2>/dev/null || true
    say "internal flash full -> installed binary to exec-safe work dir ($SDHOME)"
  else
    rm -rf "$TMP"
    die "sing-box ($((BINSZ/1024/1024))MB) doesn't fit in internal flash (~$((${SBFREE:-0}/1024/1024))MB free) and the only spare space is a FUSE/exFAT card, which can't reliably execute binaries. Free internal flash (remove old packages) or format the card as ext4, then re-run."
  fi
  rm -rf "$TMP"
  # Run-probe. For arm64/amd64 this is DECISIVE (picks the glibc-vs-musl variant that
  # actually runs). For mips/mipsle/armv7 there is ONE static build and we already
  # verified ELF + endianness above, so a failed probe here is almost always a transient
  # OOM under post-unpack memory pressure (the binary runs fine once memory settles / at
  # service start) — NOT a bad binary. Don't discard a correct binary over that.
  VOUT=$(sb_version || true)
  if [ -n "$VOUT" ]; then say "installed: $VOUT (asset ${ASSET}${SUF})"; break; fi
  case "$ASSET" in
    linux-arm64|linux-amd64)
      say "  ${ASSET}${SUF} downloaded but did not run on this libc -> trying next variant" ;;
    *)
      VOUT="(arch-verified; runtime probe skipped — low memory during install)"
      say "  ${ASSET} verified by ELF+arch; run-probe OOM'd under install memory pressure -> accepting (service will start it when memory settles)"
      break ;;
  esac
done
fi
[ -n "$VOUT" ] || die "sing-box did not run (no musl/static build matched arch '$ASSET'). Tell me the router model."

# ---- 4.5) swap for RAM-starved routers -------------------------------------
# E750/AR300M-class boxes have 128MB RAM; the ~58MB sing-box binary + geoip leaves
# almost nothing, so `sing-box check`/`run` get OOM-killed and the panel then reports
# "Server config rejected" for a perfectly valid config (and the tunnel can't run at
# all). A swapfile on PERSISTENT external storage (microSD/USB) gives it headroom.
# Idempotent: created once, re-enabled every install; skipped on roomy-RAM boxes.
# best-effort: this whole block must NEVER abort the install (it runs BEFORE the panel
# install) — so drop set -e for it and restore after.
set +e
MEMK=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
SWAPK=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$MEMK" ] && [ "$MEMK" -lt 262144 ] && [ "${SWAPK:-0}" -lt 131072 ]; then
  # need a writable, PERSISTENT (non-tmpfs) mount with room for a 256MB swapfile.
  SWAPDIR=""
  # GL auto-mounts SD/USB by LABEL (e.g. /mnt/Untitled), so a fixed path list misses it.
  # Scan /proc/mounts for any real (non-tmpfs) external mount under /mnt or /tmp/mountd,
  # then fall back to the well-known fixed paths.
  SDCANDS=$(awk '($2 ~ /^\/mnt\// || $2 ~ /^\/tmp\/mountd\//) && $3 !~ /^(tmpfs|ramfs|overlay)$/ {print $2}' /proc/mounts 2>/dev/null)
  for c in $SDCANDS /mnt/mmcblk0p1 /mnt/sda1 /mnt/sdcard /tmp/mountd/disk1_part1 /overlay; do
    [ -d "$c" ] && [ -w "$c" ] || continue
    FST=$(awk -v m="$c" '$2==m{print $3}' /proc/mounts 2>/dev/null | tail -1)
    case "$FST" in tmpfs|ramfs|"") continue;; esac          # never put swap in RAM
    FK=$(df -k "$c" 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$FK" ] && [ "$FK" -ge 307200 ] && { SWAPDIR="$c"; break; }   # >=300MB free
  done
  if [ -n "$SWAPDIR" ]; then
    SWAPF="$SWAPDIR/reality-swap"
    if [ ! -f "$SWAPF" ]; then
      say "low RAM (${MEMK}kB), no swap -> creating 256MB swap at $SWAPF"
      if dd if=/dev/zero of="$SWAPF" bs=1024 count=262144 2>/dev/null; then
        chmod 600 "$SWAPF"; mkswap "$SWAPF" >/dev/null 2>&1 || say "WARN: mkswap unavailable"
      else
        rm -f "$SWAPF" 2>/dev/null; say "WARN: could not allocate swapfile (disk full?)"
      fi
    fi
    if [ -f "$SWAPF" ]; then
      if swapon "$SWAPF" 2>/dev/null; then
        say "swap on: $(free -m 2>/dev/null | awk '/Swap/{print $2\"MB\"}')"
      else
        say "WARN: swapon failed (busybox lacks swap support? opkg install swap-utils)"
      fi
      # persist across reboot via rc.local (idempotent, portable busybox awk insert)
      RCL=/etc/rc.local
      [ -f "$RCL" ] || printf '#!/bin/sh\nexit 0\n' > "$RCL"
      if ! grep -qF "swapon $SWAPF" "$RCL" 2>/dev/null; then
        if grep -q '^exit 0' "$RCL" 2>/dev/null; then
          awk -v L="swapon $SWAPF 2>/dev/null" '/^exit 0/ && !d {print L; d=1} {print}' "$RCL" > "$RCL.tmp" && mv "$RCL.tmp" "$RCL"
        else
          echo "swapon $SWAPF 2>/dev/null" >> "$RCL"
        fi
        chmod +x "$RCL" 2>/dev/null
      fi
    fi
  else
    say "NOTE: low RAM (${MEMK}kB) but no persistent storage with 300MB free -> insert a microSD to enable swap, else sing-box may OOM."
  fi
fi
set -e   # restore strict mode after best-effort swap provisioning

# ---- 5) scripts ------------------------------------------------------------
for s in parse-link.sh rebuild.sh geo-refresh.sh postup.sh watchdog.sh ks-sync.sh ks-lib.sh \
         add-server.sh list-servers.sh del-server.sh import-links.sh sub-store.sh mac-tool.sh; do
  cp "$D/$s" "$SBDIR/$s" && chmod +x "$SBDIR/$s"
done
# MAC-on-reboot boot hook: run the randomizer early at boot (gated by the mac-onboot flag,
# self-heals to factory if the random MAC loses internet). Idempotent rc.local insert.
RCLM=/etc/rc.local
[ -f "$RCLM" ] || printf '#!/bin/sh\nexit 0\n' > "$RCLM"
if ! grep -qF "mac-tool.sh boot" "$RCLM" 2>/dev/null; then
  if grep -q '^exit 0' "$RCLM" 2>/dev/null; then
    awk '/^exit 0/ && !d {print "sh /etc/sing-box/mac-tool.sh boot >/dev/null 2>&1 &"; d=1} {print}' "$RCLM" > "$RCLM.tmp" && mv "$RCLM.tmp" "$RCLM"
  else
    echo "sh /etc/sing-box/mac-tool.sh boot >/dev/null 2>&1 &" >> "$RCLM"
  fi
  chmod +x "$RCLM" 2>/dev/null
fi
# Default-ON "random MAC on reboot" (mason's request). Do it ONCE — seed the factory MAC
# cache FIRST (so the current real MAC is remembered as factory before any randomize),
# then set the flag. A marker stops later upgrades from re-forcing it, so a user who turns
# the toggle OFF stays off across updates.
if [ ! -f "$SBDIR/.mac-onboot-defaulted" ]; then
  sh "$SBDIR/mac-tool.sh" status >/dev/null 2>&1   # caches factory MAC
  : > "$SBDIR/mac-onboot"
  : > "$SBDIR/.mac-onboot-defaulted"
  say "random-MAC-on-reboot enabled by default"
fi
# ship empty servers dir + the README/example for reference
cp -r "$D/servers/." "$SBDIR/servers/" 2>/dev/null || true
# Remove ONLY the shipped reference example (rebuild.sh globs servers/*.json, so the
# example must never become a live server). PRESERVE any srv-*.json the user already
# added -> re-running the installer to upgrade does NOT wipe their configured servers.
rm -f "$SBDIR/servers/server.example.json" 2>/dev/null || true

# record the installed version so the panel can show it + check for updates
if [ -f "$D/VERSION" ]; then cp "$D/VERSION" "$SBDIR/version"; else echo "unknown" > "$SBDIR/version"; fi
# post-install marker (fresh<10min) — the panel shows "✅ updated to vX" after the
# Update button re-runs this installer, then it expires.
cp -f "$SBDIR/version" "$SBDIR/.updated_to" 2>/dev/null || true
say "installed version: $(cat "$SBDIR/version" 2>/dev/null)"

# ---- 6) sing-box service ---------------------------------------------------
cat > /etc/init.d/sing-box <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
  # No servers configured -> nothing to tunnel. Don't run sing-box at all, so the
  # status honestly reads OFF instead of autostarting on boot into a DIRECT config
  # and showing "running" with no tunnel. Internet stays up via normal routing.
  [ -n "$(ls /etc/sing-box/servers/*.json 2>/dev/null)" ] || return 0
  # Respect the user's desired state: only autostart on boot if the VPN was left ON.
  # The supervisor (watchdog.sh, cron) is what (re)starts it when desired -> this also
  # keeps boot honest and lets a user-OFF survive a reboot.
  [ "$(cat /etc/sing-box/vpn.enabled 2>/dev/null)" = "1" ] || return 0
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
# Desired-state flag (source of truth for the supervisor + boot autostart + KS gate).
# Preserve an existing choice across upgrades; otherwise default ON iff servers are
# already configured (matches the previous "start if servers exist" behaviour).
if [ ! -f "$SBDIR/vpn.enabled" ]; then
  if [ -n "$(ls "$SBDIR"/servers/*.json 2>/dev/null)" ]; then echo 1 > "$SBDIR/vpn.enabled"; else echo 0 > "$SBDIR/vpn.enabled"; fi
fi
[ -f "$SBDIR/ks.enabled" ] || echo 0 > "$SBDIR/ks.enabled"
# fresh install with no servers (or VPN left off): leave sing-box stopped.
[ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" = "1" ] || /etc/init.d/sing-box stop 2>/dev/null || true

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

# ---- 9) cron: LAN forwarding re-apply, supervisor + killswitch, geo cache --
# supervisor (auto-reconnect) and killswitch re-assert every 30s. cron's finest
# granularity is 60s, so each runs twice a minute (:00 and :30).
CR=/etc/crontabs/root; touch "$CR"
# drop any prior lines we own, then re-add cleanly (idempotent across upgrades)
grep -vE 'sing-box/(postup|watchdog|geo-refresh|ks-sync|sub-store)' "$CR" > "$CR.tmp" 2>/dev/null || true; mv "$CR.tmp" "$CR"
{
  echo '*/2 * * * * /bin/sh /etc/sing-box/postup.sh'
  echo '*/5 * * * * /bin/sh /etc/sing-box/geo-refresh.sh'
  echo '* * * * * /bin/sh /etc/sing-box/watchdog.sh'
  echo '* * * * * sleep 30; /bin/sh /etc/sing-box/watchdog.sh'
  echo '* * * * * /bin/sh /etc/sing-box/ks-sync.sh'
  echo '* * * * * sleep 30; /bin/sh /etc/sing-box/ks-sync.sh'
  # Happ-style auto-update: re-pull every saved subscription every 6h (no-op if none)
  echo '17 */6 * * * /bin/sh /etc/sing-box/sub-store.sh refresh all >/dev/null 2>&1'
} >> "$CR"
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
  # `start` (not `restart`): uhttpd re-reads the CGI + index.html per request, so a
  # restart isn't needed to pick up panel changes — and restarting would kill an
  # in-progress self-update (the Update button re-runs this installer). start is a
  # no-op when already running, and starts it on a fresh install.
  /etc/init.d/vpn-panel start 2>/dev/null || true
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
    # Only the lua rpc handler / validator need a FULL nginx restart (to drop OpenResty's
    # cached lua) — and that restart bounces the admin to /#/login. So detect whether they
    # ACTUALLY changed (vs the deployed copies) BEFORE overwriting; if only JS/scripts
    # changed, a graceful reload suffices and the user is NOT kicked to login (mason: "при
    # обновлении тоже выкидывает"). First install (no deployed copy) -> cmp fails -> restart.
    LUA_CHANGED=0
    cmp -s "$D/sdk4-tab/reality.oui.lua" /usr/lib/oui-httpd/rpc/reality 2>/dev/null || LUA_CHANGED=1
    cmp -s "$D/sdk4-tab/reality.validator.lua" /usr/share/gl-validator.d/reality.lua 2>/dev/null || LUA_CHANGED=1
    cp "$D/sdk4-tab/reality.oui.lua"                    /usr/lib/oui-httpd/rpc/reality
    cp "$D/sdk4-tab/reality.validator.lua"              /usr/share/gl-validator.d/reality.lua
    if [ "$LUA_CHANGED" = 1 ]; then
      # lua handler changed -> MUST drop OpenResty's cache with a full restart (this
      # bounces login); then immediately rebuild GL's session-ws bridge. Order matters.
      say "rpc handler changed -> nginx restart (panel re-login needed once)"
      /etc/init.d/nginx restart 2>/dev/null || true; /etc/init.d/gl-ngx-session restart 2>/dev/null || true
    else
      # only static/scripts changed -> graceful reload keeps workers + the session bridge
      # alive, so NO /#/login bounce.
      /etc/init.d/nginx reload 2>/dev/null || /etc/init.d/nginx restart 2>/dev/null || true
    fi
    # nginx needs a moment to come back up before the self-diagnostic curls below;
    # otherwise they race the restart and (under set -e) a transient curl failure
    # (exit 56) aborts the install right before step 10 / the DONE message.
    sleep 3
    # survive firmware upgrades
    for p in /usr/share/oui/menu.d/reality.json /www/views/gl-sdk4-ui-reality.common.js.gz \
             /www/views/gl-sdk4-ui-reality.common.js \
             /usr/lib/oui-httpd/rpc/reality /usr/share/gl-validator.d/reality.lua; do
      grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf 2>/dev/null || true
    done
    # self-diagnostic (prints to the install log so we can confirm the tab will load,
    # or pinpoint a /#/login bounce: view 404 = serving issue, empty rpc = handler issue,
    # gl-ngx-session ABSENT = session-bridge issue).
    VJS=$(curl -s -o /dev/null -w '%{http_code}/%{size_download}b' --max-time 5 http://127.0.0.1/views/gl-sdk4-ui-reality.common.js 2>/dev/null || true)
    VGZ=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Accept-Encoding: gzip' http://127.0.0.1/views/gl-sdk4-ui-reality.common.js 2>/dev/null || true)
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
