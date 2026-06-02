#!/bin/sh
# Stop sing-box if router lost internet (auto-recovery). Cron: every minute.
pidof sing-box >/dev/null 2>&1 || exit 0
ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && exit 0
ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && exit 0
/etc/init.d/sing-box stop 2>/dev/null
killall sing-box 2>/dev/null
ip rule del pref 500 2>/dev/null
logger "sb-watchdog: no internet -> stopped sing-box"
