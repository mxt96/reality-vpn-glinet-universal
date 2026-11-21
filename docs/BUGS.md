# Bugs addressed by the 2.0 beta

| Problem | Fix and verification |
| --- | --- |
| Update check silently returned `Latest: unknown` | Single-command RPC capture, Lua version parsing, IPv4 raw/API/SOCKS fallbacks and explicit UI errors; see [UPDATES.md](UPDATES.md) |
| `direct-dns` used `detour: direct`; sing-box 1.14 passed `check` but exited at startup | Remove the empty direct detour; boot real sing-box in QEMU |
| Rebuild reported success after a dead daemon | Check API + TUN after restart; restore previous config and return failure on timeout |
| Manual server selection reset after restart | Save selection, build a matching selector default and persist core cache; rebuild/reboot checks |
| ICMP filtering stopped a working VPN | Probe HTTPS through the local SOCKS listener; verified with ICMP OUTPUT blocked |
| LAN forwarding was missing until periodic `postup.sh` after boot | Explicit LAN policy routes plus lifecycle/firewall/interface reconciliation |
| Broad TUN forwarding could override device restrictions | Shared policy backend and explicit interface guards in both IP families |
| Device rules could have marks overwritten by whole-network rules | Device-first ordering and terminal return after marking |
| Subscription deletion discarded data even when rebuild failed | Snapshot owned servers/metadata and restore on failure; backend tests |
| Subscription staging lacked new rebuild helper files | Copy runtime/render helpers and settings into isolated validation stage; real subscription add/refresh/delete in QEMU |
| BusyBox 1.33 OpenWrt `find` lacks `-delete`, leaving subscription stages behind | Remove only the directory returned by `mktemp`; rerun subscription lifecycle on OpenWrt |
| New nft generator used reserved chain name `mark` | Rename chain and validate real nft rules in the guest kernel before applying |
| Direct IPv6 did not discover the WAN's separate DHCPv6 network | Use routes from the same WAN L3 device; successful IPv6 baseline before local-only block |
| Installer overwrote the native GL kill-switch setting | Stop mirroring independent package flags into native GL routing policy |
| Changing procd START order left duplicate old boot symlinks | Disable and re-enable owned services when upgrading their init scripts |
| Private installer umask left CGI without world-execute permission, causing uhttpd HTTP 403 | Set explicit public directory/CGI modes; actual login and authenticated status checks passed |
| Switching tabs could reload a form after typing began | Make tab navigation local and test delayed responses with an explicit save-response wait |
| UI confused desired ON with verified connectivity | Separate desired state, observed daemon and recent HTTPS health result |

An IPv6 leak in the original sing-box `strict_route` configuration was **not
established**. Earlier suspicion alone is not counted as a confirmed bug. The beta
uses explicit IPv6 blocking for the IPv4-only sing-box path and tests a working
IPv6 direct baseline before applying restrictions.

Remaining constraints and untested integrations are listed in
[UPGRADE.md](UPGRADE.md) and [TESTING.md](TESTING.md). The beta is not certified
against vendor acceleration, adversarial MAC spoofing or zero-packet leak windows
through all GL.iNet firewall reload paths.
