# Verification of 2.0.0-beta.1

## Automated regressions

Backend tests run in Alpine 3.22 with BusyBox shell, Python 3, Lua 5.1 and cjson:

```sh
python3 tests/parser_regressions.py
python3 tests/cli_regressions.py
python3 tests/backend_regressions.py
python3 tests/routing_test.py
python3 tests/manager_regressions.py
python3 tests/update_regressions.py
```

There are 66 backend tests, including parser encoding, subscription rollback,
real staged-rebuild helper availability, device precedence, direct/native tunnel
fail-closed behavior, private backup versus diagnostic output, daemon failure
rollback and HTTPS monitoring without ICMP. Adapters isolate host routing changes;
these tests alone do not establish packet-forwarding behavior.

Browser tests use Chromium, Playwright and Vue 2.7.16:

```sh
npm install --no-save playwright@1.56.1 vue@2.7.16
npx playwright install --with-deps chromium
node tests/ui-panel.cjs
node tests/ui-manager.cjs
```

For system Chromium, set `CHROMIUM_PATH` to its executable. Tests cover mobile
layout, honest status, non-disruptive favorites, explicit apply, deletion
cancellation, errors, local-only policy submission, safe device labels, domain
routing and Russian language switching. GitHub Actions runs both suites.

## Executed packet and lifecycle checks

Lab: official **OpenWrt 21.02.7 x86_64**, kernel **5.4.238**, QEMU **10.0 TCG**,
sing-box **1.14.4 musl**. Router: 768 MiB RAM; two independent OpenWrt clients:
192 MiB each. Two emulated LAN NICs share the router bridge. One is used as the
Ethernet-side client; the other simulates a Wi-Fi peer at the IP/bridge layer.
No physical radio, switch silicon or GL proprietary firmware is emulated.

Official image/kernel SHA-256 values and the sing-box archive digest were checked.
A local package mirror fetched official packages over HTTPS and retained opkg's
signature checks. Proxy/certificate setup was specific to the cloud lab.

The following were exercised with real packets:

- Full installer on OpenWrt, empty configuration, later import of two server links.
- VLESS/REALITY and Hysteria2 encrypted links to controlled sing-box server inbounds.
  HTTP marker responses originated behind the server's SOCKS test adapter.
  HTTPS health requests also traversed the encrypted connection.
- Both clients reached each other. After applying local-only to client A, A could
  still ping B, but failed to fetch either the WAN fixture or the VPN fixture.
  B continued fetching through VPN.
- A working direct IPv6 client-to-WAN baseline used an explicit lab IPv6 route
  and NAT6. Applying local-only then blocked the same IPv6 destination.
- Local-only restrictions remained after switching sing-box off; B could still
  fetch directly through the router while A remained blocked.
- Manual Hysteria2 selection survived rebuild. Firewall restart reapplied policy
  guards and allowed B's VPN traffic. ICMP OUTPUT blocking did not stop a healthy
  VPN. SIGKILL of sing-box was followed by supervisor recovery and client traffic.
- Real nftables 0.9.6 rules compiled and ran in the guest kernel using an `inet fw4`
  fixture with forward/srcnat chains. nft guards blocked A while B used VPN.
  This is a tested nft backend fixture, **not a complete stock fw4 firmware test**.
- A real kernel WireGuard tunnel connected router and peer guest. Client A,
  assigned to `wgclient`, fetched `WG_LAB_OK` from the remote tunnel endpoint.
  Handshake timestamps and encrypted byte counters advanced.
- With global internet blocking enabled and sing-box stopped, assigned WireGuard
  traffic still worked. The unassigned peer's WAN request was blocked, and
  router-originated management traffic remained possible.
- Deleting the assigned WireGuard interface blocked client A's WAN/VPN requests
  without falling back to another route. Router access remained available.
- After reboot, the daemon and forwarding guard started automatically; Hysteria2
  selection and local-only policy persisted. Client A retained local ping but could
  not fetch the WAN fixture, while B fetched through VPN.
- Standalone CGI rejected unauthenticated access, accepted the router-password
  login, returned authenticated manager status and rejected GET mutations.
- Real subscription add → refresh → delete completed and retained manual servers.

The fw3 lifecycle script made 19 successful assertions; the nft/native-tunnel
script made 14, in addition to protocol, IPv6 baseline and subscription checks.
Tests use controlled endpoints, not a public-VPS performance benchmark.

## Still required before a stable release

Physical Flint 2 and the exact Beryl model, their installed vendor firmware,
CPU architecture, GL SDK4 RPC/session integration, native GL-created OpenVPN and
WireGuard profiles, hardware acceleration, DSA/swconfig, actual Wi-Fi isolation,
full stock fw4, router DNS/AdGuard integration, multi-WAN failover and stress/load
must be tested separately. OpenVPN interface policy uses the same routing backend
but a live OpenVPN session was not exercised in this lab.

For a target device, record its model, GL firmware build, `/etc/openwrt_release`,
`ubus call system board`, firewall backend and acceleration state. Capture packets
on all WAN/VPN interfaces during reboot, firewall reload and tunnel failure.
Success after a reload does not prove that no individual packet escaped during it.

## Update-check hotfix (2.0.0-beta.2)

The additional 11 updater tests and native browser assertions cover the
`Latest: unknown` report. Live HTTPS requests verified raw and API response
formats. Forwarding and physical-hardware results above refer to beta.1; this
hotfix changes update checking and UI error handling, not packet routing.
