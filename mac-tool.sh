#!/bin/sh
# mac-tool.sh — randomize / set / reset the WAN MAC on GL.iNet (OpenWrt) routers.
# Subcommands (called by the panel RPC reality.oui.lua, and at boot):
#   status            -> dev / current / factory / onboot flag
#   random            -> apply a fresh locally-administered random MAC, print it
#   reset             -> restore the cached factory MAC
#   onboot on|off     -> toggle "random MAC on every reboot"
#   boot              -> if onboot is set: apply a random MAC, then SELF-HEAL (revert
#                        to factory if the new MAC can't reach the internet)
# MAC changes target the WAN device's uci `device` section (works for ethernet WAN).
SBDIR=${SBDIR:-/etc/sing-box}
FLAG="$SBDIR/mac-onboot"
FACT="$SBDIR/mac-factory"
CHECK_URL="https://chat.tradefilebox.net/"
# oui-httpd calls us with a minimal PATH that lacks /sbin & /usr/sbin where ip/uci live,
# so the WAN device came back empty in the panel. Force a full PATH.
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

wan_dev() {
  d=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  # fallback: the uci wan interface's device, then common names
  [ -n "$d" ] || d=$(uci -q get network.wan.device)
  [ -n "$d" ] || d=$(uci -q get network.wan.ifname)
  [ -n "$d" ] || for x in eth0 wan wwan eth1; do [ -e "/sys/class/net/$x" ] && { d=$x; break; }; done
  echo "$d"
}

# find the uci `@device[N]` section whose .name matches the WAN device (e.g. eth0)
wan_uci_dev() {
  d=$(wan_dev); [ -n "$d" ] || return 1
  i=0
  while uci -q get "network.@device[$i]" >/dev/null 2>&1; do
    [ "$(uci -q get "network.@device[$i].name")" = "$d" ] && { echo "@device[$i]"; return 0; }
    i=$((i+1))
  done
  return 1
}

cur_mac() { d=$(wan_dev); [ -n "$d" ] && cat "/sys/class/net/$d/address" 2>/dev/null; }

# factory MAC = whatever the WAN MAC was the FIRST time we ran (cached before any change)
factory_mac() {
  [ -s "$FACT" ] && { cat "$FACT"; return 0; }
  m=$(cur_mac); [ -n "$m" ] && printf '%s\n' "$m" > "$FACT"; printf '%s\n' "$m"
}

rand_mac() {
  # locally-administered (02:..), unicast — safe random MAC
  r=$(openssl rand -hex 5 2>/dev/null | sed 's/\(..\)/\1:/g; s/:$//')
  [ -n "$r" ] && echo "02:$r"
}

apply_mac() {   # $1 = mac
  sec=$(wan_uci_dev) || return 1
  dev=$(wan_dev)
  uci set "network.$sec.macaddr=$1" 2>/dev/null || return 1
  uci commit network 2>/dev/null
  # Reconfigure ONLY the WAN device. A full `/etc/init.d/network reload` also blips
  # br-lan, which drops the admin's panel session and bounces them to /#/login (mason
  # hit this). Set the MAC on the WAN device directly + re-DHCP just the WAN interface;
  # the LAN/panel stays up. Fall back to a full reload only if the WAN didn't recover.
  if [ -n "$dev" ]; then
    ip link set dev "$dev" down 2>/dev/null
    ip link set dev "$dev" address "$1" 2>/dev/null
    ifup wan 2>/dev/null
    sleep 5
    ip route show default 2>/dev/null | grep -q default || /etc/init.d/network reload >/dev/null 2>&1
  else
    /etc/init.d/network reload >/dev/null 2>&1
  fi
}

have_net() { curl -s --max-time 6 -o /dev/null "$CHECK_URL" 2>/dev/null; }

case "$1" in
  status)
    factory_mac >/dev/null
    echo "dev=$(wan_dev)"
    echo "current=$(cur_mac)"
    echo "factory=$(factory_mac)"
    echo "onboot=$([ -f "$FLAG" ] && echo 1 || echo 0)"
    ;;
  random)
    factory_mac >/dev/null          # cache factory BEFORE the first change
    NEW=$(rand_mac); [ -n "$NEW" ] || { echo ERR; exit 1; }
    apply_mac "$NEW" && echo "$NEW" || echo ERR
    ;;
  reset)
    F=$(factory_mac); [ -n "$F" ] || { echo ERR; exit 1; }
    apply_mac "$F" && echo "$F" || echo ERR
    ;;
  onboot)
    case "$2" in
      1|on)  factory_mac >/dev/null; : > "$FLAG"; echo on ;;
      0|off) rm -f "$FLAG"; echo off ;;
      *)     echo "onboot=$([ -f "$FLAG" ] && echo 1 || echo 0)" ;;
    esac
    ;;
  boot)
    [ -f "$FLAG" ] || exit 0
    factory_mac >/dev/null
    NEW=$(rand_mac); [ -n "$NEW" ] && apply_mac "$NEW"
    # SELF-HEAL: if the random MAC doesn't get internet (e.g. MAC-whitelisted network),
    # roll back to the factory MAC so the router is never left offline after a reboot.
    i=0; ok=0
    while [ $i -lt 6 ]; do sleep 5; have_net && { ok=1; break; }; i=$((i+1)); done
    [ "$ok" = 1 ] || apply_mac "$(factory_mac)"
    ;;
  *) echo "usage: mac-tool.sh status|random|reset|onboot on|off|boot" ; exit 1 ;;
esac
