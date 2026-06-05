#!/bin/sh
# supervisor (was: watchdog) — keep sing-box matching the user's DESIRED state.
# Cron: every minute. Driven by the /etc/sing-box/vpn.enabled flag (1=on,0/absent=off):
#
#   desired ON  + servers + internet  -> ensure tunnel UP   (auto-RECONNECT: if it
#                                        died / was never started after a reboot or
#                                        an upstream outage, bring it back + re-route)
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
stop_sb(){ /etc/init.d/sing-box stop 2>/dev/null; killall sing-box 2>/dev/null; ip rule del pref 500 2>/dev/null; }

if want_on && have_servers; then
  if internet; then
    if ! sb_running; then
      /etc/init.d/sing-box start 2>/dev/null
      sleep 4
      sh "$SBDIR/postup.sh" 2>/dev/null
      logger "sb-supervisor: tunnel (re)connected"
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
