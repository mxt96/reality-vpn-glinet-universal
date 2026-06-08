#!/bin/sh
# supervisor (was: watchdog) — keep sing-box matching the user's DESIRED state.
# Cron: every minute. Driven by the /etc/sing-box/vpn.enabled flag (1=on,0/absent=off):
#
#   desired ON  + servers + internet  -> ensure tunnel UP   (auto-RECONNECT: if it
#                                        died / was never started after a reboot or
#                                        an upstream outage, bring it back + re-route)
#   desired ON  + tunnel up-but-DEAD   -> process alive + singtun0 present but no traffic
#                                        actually passes (server blip / handshake lost /
#                                        VPS restart). Fail the LAN OPEN immediately via
#                                        postup, then rate-limited restart to reconnect.
#                                        Without this check a stuck tunnel strands the LAN
#                                        with "VPN on but no internet, and none without it".
#   desired ON  + no internet          -> stop tunnel so LAN fails open (when KS off);
#                                        retry automatically next minute when WAN returns
#   desired OFF                        -> ensure tunnel stopped
#
# This is what makes a downstream router (e.g. Mudi behind Beryl) reconnect on its
# own "as soon as it becomes possible" instead of needing a manual re-enable.
# The killswitch is reconciled separately by ks-sync.sh / ks-lib.sh.
SBDIR=${SBDIR:-/etc/sing-box}

want_on(){ [ "$(cat "$SBDIR/vpn.enabled" 2>/dev/null)" = "1" ]; }
have_servers(){ [ -n "$(ls "$SBDIR"/servers/*.json 2>/dev/null)" ]; }
sb_running(){ pidof sing-box >/dev/null 2>&1; }
internet(){ ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }
# tunnel HEALTH (not just process liveness): does traffic actually pass through singtun0?
# A process can be alive with singtun0 up yet carry nothing (server down / handshake lost).
# curl --interface forces egress out singtun0 (SO_BINDTODEVICE) so a dead tunnel fails the
# probe. (ping -I only sets the source addr -> kernel may route it out the WAN -> false-OK;
# don't use ping here.) No curl -> skip probe, fall back to liveness (no regression).
tunnel_ok(){
  command -v curl >/dev/null 2>&1 || return 0
  for _t in 1 2 3; do curl -s --max-time 5 --interface singtun0 -o /dev/null http://1.1.1.1 2>/dev/null && return 0; sleep 1; done; return 1
}
stop_sb(){ /etc/init.d/sing-box stop 2>/dev/null; killall sing-box 2>/dev/null; ip rule del pref 500 2>/dev/null; }

if want_on && have_servers; then
  if internet; then
    if ! sb_running; then
      /etc/init.d/sing-box start 2>/dev/null
      sleep 4
      sh "$SBDIR/postup.sh" 2>/dev/null
      logger "sb-supervisor: tunnel (re)connected"
    elif ! tunnel_ok; then
      # up-but-dead: process alive but nothing flows. Fail the LAN OPEN now (postup drops
      # the policy route when the tunnel can't carry traffic) so internet survives; then
      # nudge a reconnect, rate-limited to once/120s so we don't fight sing-box's own
      # backoff or thrash while the upstream VPS is genuinely down.
      sh "$SBDIR/postup.sh" 2>/dev/null
      now=$(date +%s); last=$(cat /tmp/sb-redead.ts 2>/dev/null || echo 0)
      if [ $((now - last)) -gt 120 ]; then
        echo "$now" > /tmp/sb-redead.ts
        /etc/init.d/sing-box restart 2>/dev/null
        sleep 4
        sh "$SBDIR/postup.sh" 2>/dev/null
        logger "sb-supervisor: tunnel up-but-dead -> failed LAN open + restarted sing-box"
      fi
    fi
  else
    # no upstream — drop the tunnel so the router fails open (unless killswitch holds
    # it shut by design); supervisor will reconnect automatically when WAN is back.
    if sb_running; then stop_sb; logger "sb-supervisor: no internet -> tunnel down, will auto-retry"; fi
  fi
else
  # user wants VPN off (or no servers) -> make sure nothing is running.
  if sb_running; then stop_sb; fi
fi
