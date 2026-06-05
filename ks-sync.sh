#!/bin/sh
# Killswitch sync — reconcile live firewall rules with desired state every minute.
# All backend logic (fw4/nftables vs fw3/iptables, the VPN gate, can't-strand
# safety) lives in ks-lib.sh so panel/, the native GL tab, and this cron agree.
SBDIR=${SBDIR:-/etc/sing-box}
. "$SBDIR/ks-lib.sh"
ks_enforce
