# VPN manager 2.0 beta

This is a testable first upgrade of the router client. The backend is **sing-box**,
not Xray. REALITY is a VLESS TLS mechanism, not the name of a separate VPN engine.
WireGuard and OpenVPN remain configured by GL.iNet and keep their existing keys.
This beta needs validation on physical GL.iNet hardware before a stable release.

## Open the manager

- GL SDK4: VPN → Sing-box VPN → **Device access, routing, DNS and diagnostics**.
  This uses the existing Admin-Token session through `/rpc`.
- Other firmware: `http://<LAN-IP>:8088/manager.html`, using the router admin password.
  English and Russian are available. The original panel remains at `/`.
- The standalone listener binds the LAN IPv4 address and loopback. Use the native
  GL.iNet HTTPS interface when available; the standalone panel uses HTTP on LAN.

## Устройство LAN без интернета, сосед по Wi-Fi с интернетом

1. Откройте **Устройства**. Найдите устройство по имени и MAC, либо добавьте MAC
   вручную. Для постоянного правила отключите рандомизацию MAC на этом устройстве.
2. Выберите **Только локальная сеть** и примените правило.
3. Для устройства Wi-Fi оставьте **По умолчанию**, либо назначьте нужный VPN.
4. Устройства в одном LAN-мосту сохраняют обмен данными. Правило ограничивает
   маршрутизируемый выход в интернет, включая IPv6, WAN и VPN.

This is a MAC policy, not a physical switch-port assignment. For an untrusted
Ethernet device, create a separate routed network/VLAN in GL.iNet/LuCI first, add
its Linux interface in **Routing → Advanced network settings**, and apply a
**Whole existing network / VLAN** policy. The manager does not guess switch port
numbers or rewrite DSA/swconfig. Access between configured local interfaces is
allowed by these explicit policies; keep only trusted local interfaces in that list.
Router services, including its DNS resolver, remain reachable. A local-only device
can therefore use an allowed local service as a relay if that service provides one.
MAC spoofing and application-level relaying require a separate security boundary.
AP/bridge mode and vendor hardware acceleration are outside this beta's guarantees.

## Policy semantics

| Setting | Result |
| --- | --- |
| Use default | Remove the explicit policy; use the selected default route |
| Local network only | Allow configured local destinations; drop other forwarding in both IP families |
| Direct | Pin to the selected netifd WAN network; do not borrow another VPN's default route |
| Sing-box VPN | Pin to `singtun0`; block when it is unavailable, even with global blocking off |
| WireGuard / OpenVPN | Pin to an existing `wg*`, `awg*`, `tun*`, `tap*` or `ovpn*` Linux interface; block when unavailable |

Device policies precede whole-network policies. Explicit Direct/native-VPN rules
are exceptions to global internet blocking. With blocking armed, unassigned
clients cannot use another tunnel merely because its name looks like a VPN.
Native tunnel addressing, peer routes, return routes, DNS and NAT must already
work in GL.iNet. Selecting an interface does not create a native VPN profile.

The default can be **Sing-box VPN** or **Router routing (GL.iNet)**. Select Router
routing when GL.iNet should own global routing, then assign individual devices to
sing-box as needed. Router-originated traffic is not captured by a global TUN
route; sing-box binds its upstream connections to the selected physical WAN.
Only one WAN network is selected at a time. Interface events reapply its routes;
this is not automatic multi-WAN priority selection or load balancing.

Per-policy tables are 2201–2328, priorities 100–227 and mark bits `0x00ff0000`.
Default LAN rules use priority 500/table 2022. Deletion matches the manager's
mark/table tuple; other rules with the same priority are retained. Vendor GL
routing/acceleration rules must be checked for conflicts on each target firmware.

## Domain routing and DNS

All traffic, selected domain suffixes only, and selected domain suffixes bypassing
VPN are supported. Blocked suffixes are rejected inside sing-box. These profiles
apply only to traffic entering sing-box; a Direct or native-VPN policy does not
pass through its domain filtering.

UDP DNS and DNS over HTTPS configure sing-box's DNS transport. The direct bootstrap
resolver has no `detour: direct`, which causes a startup failure in sing-box 1.14.
The router's dnsmasq/AdGuard Home configuration is preserved. **This does not
redirect all router DNS into the tunnel** or promise DNS leak prevention for
clients using the router's existing resolver. Configure that resolver separately
when tunneled DNS is required. Client DoH/ECH and cached addresses also limit
sniff-based domain matching. Automatic AdGuard integration remains future work.

The sing-box TUN is IPv4-only in this beta. Forwarded IPv6 for its assigned clients
is blocked with terminal unreachable routes and firewall rules. Direct/native
policies can use IPv6 when their configured interfaces support it. Dual-stack
sing-box TUN support is a separate future change.

## Reliability

- Configurations are generated in a private candidate file, checked by the core,
  and installed atomically. Runtime readiness (API + TUN) is checked after restart.
  Failure reports an error and restores the previous configuration.
- Selection is saved in `selected` and used as the selector default; the sing-box
  cache is persistent. Favorites are saved immediately and rebuilt explicitly.
- A procd monitor checks HTTPS through the local SOCKS listener. ICMP is not a
  prerequisite. Failed probes use a threshold/backoff before restart. This checks
  proxy connectivity; it is not an end-to-end probe from every LAN client.
- Startup, firewall includes and interface hooks reconcile policy rules. Cron is
  a fallback. Do not interpret this as a proven zero-packet leak guarantee during
  every vendor firewall reload; physical-device packet capture is still required.
- Standard OpenWrt software/hardware flow offloading is disabled when explicit
  policies are applied. Vendor acceleration must be disabled in GL.iNet separately.
- The installer pins sing-box **1.14.4** and verifies the release archive SHA-256.
  A matching installed version is reused; its executable provenance is not
  retrospectively verified. Upgrading the pin requires updating the checksum file.
- Subscription refresh failures retain the previous servers. Refresh interval is
  1–168 hours, checked hourly. Automatic refresh can be delayed until the next tick.

## Backup and diagnostics

**Service → Download backup** exports settings, policies, server credentials,
favorites, selection, desired flags and saved subscriptions as JSON. Store this
file offline. It contains secrets. Diagnostics export excludes server credentials
and subscription URLs, but contains local network/routing information.

Restore is currently an administrator operation, not a one-click browser action.
On a trusted computer, extract only the known files to an empty directory:

```python
import json, pathlib, re
backup = json.load(open('vpn-backup.json'))
assert backup['schema'] == 1
out = pathlib.Path('vpn-restore')
out.mkdir(mode=0o700, exist_ok=False)
fixed = {'settings.json', 'policies.json', 'selected', 'favorites', 'vpn.enabled', 'ks.enabled'}
for name, contents in backup['files'].items():
    assert name in fixed or re.fullmatch(r'(servers|subs)/[A-Za-z0-9][A-Za-z0-9_.-]*', name)
    assert isinstance(contents, str)
    target = out / name
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.write_text(contents)
    target.chmod(0o600)
```

Stop `vpn-monitor` and sing-box, keep a separate copy of `/etc/sing-box`, and copy
these files into `/etc/sing-box` over SSH. Do not restore the binary or generated
configuration from another router architecture. Run `sh /etc/sing-box/rebuild.sh`
and `lua /etc/sing-box/manager.lua apply`, inspect their results, then start
`vpn-monitor`. Removing old servers/subscriptions that are absent from the backup
is also an explicit administrator step. This procedure is not an atomic full restore.

## Scope still requiring work

Happ encrypted proprietary subscriptions, Xray/XHTTP, physical port/VLAN creation,
automatic multi-WAN failover, native AdGuard DNS changes, GoodCloud/mobile SDK
integration, one-click restore and binary rollback are not implemented here.
The shared browser UI adds the common controls; the existing GL SDK4 server view
is retained. See [TESTING.md](TESTING.md) for tested platforms and limitations.
