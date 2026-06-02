# reality-vpn-glinet-universal

Self-hosted **Reality / Hysteria2 VPN** for **GL.iNet** routers, powered by
[sing-box](https://github.com/SagerNet/sing-box). **Creds-free and arch-universal:**
the repo contains **no binary and no credentials** — the installer downloads the
correct sing-box for your router's CPU at install time, and **you bring your own
server** by pasting a share-link.

With **zero servers configured the config is valid and routes DIRECT**, so the
router keeps normal internet until you add a server.

## You'll need a server

This is the **client** side (your router). You also need a **server** running
sing-box with a **Reality (VLESS)** or **Hysteria2** inbound — any small VPS
works. Set one up from the official [sing-box docs](https://sing-box.sagernet.org/),
then copy its **share-link** (`vless://…security=reality…` or `hysteria2://…`).
That link is all you paste here — your server's keys never go into this repo.

## One-command install

On the router (SSH in as root):

```sh
cd /tmp
curl -fsSL https://github.com/OWNER/reality-vpn-glinet-universal/archive/refs/heads/main.tar.gz | tar xz
cd reality-vpn-glinet-universal-main
sh install.sh
```

Replace `OWNER` with the GitHub account that hosts this repo. No `curl` on the
router? `opkg update && opkg install curl`. You can also download the repo ZIP
from GitHub and `scp` it over instead.

`install.sh` will:
1. detect the CPU arch (`uname -m` + `opkg print-architecture`),
2. fetch the **latest stable** sing-box release tag from GitHub,
3. download + extract the matching asset, `file`-verify arch/endianness,
4. install it (to `/usr/bin`, or microSD `/mnt/mmcblk0p1/sing-box/` with a PATH
   symlink if rootfs is tight), install scripts, an init.d service and cron jobs,
5. generate a valid DIRECT-only config (VPN off until you add a server).

## Web control panel (browser, no terminal) — :8088

The installer also deploys a small **web control panel** (uhttpd + a POSIX-sh
CGI), so you manage everything from a **browser on any firmware** (including old
fw 3.x like the Mudi):

1. After install, open **`http://<router-LAN-ip>:8088`** in a browser on the LAN
   (e.g. `http://192.168.8.1:8088`).
2. Log in with your **router admin password** (validated against the router's own
   `/etc/shadow` root entry — no separate panel account).
3. Paste a `vless://…security=reality…` or `hysteria2://…` **share-link** into the
   add-server field and submit — **no terminal needed**. The panel parses it,
   writes `servers/<tag>.json` and rebuilds the config for you.

The panel also gives you VPN on/off, a kill-switch toggle, proxy/server select,
IP/geo + ping, a speedtest, server list/delete, and a change-password action.
Requires `uhttpd` and `openssl` on the router (install warns, doesn't fail, if
they're missing: `opkg update && opkg install uhttpd openssl-util`). The panel
binds `0.0.0.0:8088` and survives firmware upgrades via `/etc/sysupgrade.conf`.

## Add your server (by share-link)

```sh
# Reality (VLESS):
sh /etc/sing-box/add-server.sh 'vless://UUID@HOST:PORT?security=reality&pbk=PUBKEY&sid=SHORTID&sni=SNI&fp=chrome&flow=xtls-rprx-vision#myserver'

# Hysteria2:
sh /etc/sing-box/add-server.sh 'hysteria2://PASSWORD@HOST:PORT?sni=SNI#myserver'

sh /etc/sing-box/list-servers.sh           # show configured servers
sh /etc/sing-box/del-server.sh myserver    # remove one
```

> **Terminal is optional.** The commands below are an advanced fallback;
> the web panel above does the same thing from a browser.

`add-server.sh` parses the link into `servers/<tag>.json` and rebuilds the
config. You can also hand-write `servers/<tag>.json` (see
[`servers/server.example.json`](servers/server.example.json)) — every value is a
placeholder you replace with your own. Add/change/remove servers anytime; no
need to reinstall the package.

## Supported routers / architectures

The installer maps your arch to a sing-box release asset:

| Router CPU                                   | `uname -m`        | sing-box asset            |
|----------------------------------------------|-------------------|---------------------------|
| ARM64 (MT3000/MT3600/MT6000, Flint, Slate AX)| `aarch64`/`arm64` | `linux-arm64`             |
| ARMv7 / ARMv6                                 | `armv7*`/`armv6*` | `linux-armv7`             |
| MIPS big-endian (ath79 / QCA, e.g. AR750)    | `mips`            | `linux-mips-softfloat`    |
| MIPS little-endian (ramips / MT76xx)         | `mipsel`/`mipsle` | `linux-mipsle-softfloat`  |
| x86_64 (GL-x86 / VM)                          | `x86_64`          | `linux-amd64`             |

Unsupported arch → the installer aborts with a clear error.

## Firmware note

- **GL.iNet fw 4.x (SDK4):** the installer auto-detects the SDK4 UI stack and
  installs a **native "Reality" tab in the router's VPN menu** — *in addition to*
  the `:8088` web panel. You get on/off, kill-switch, proxy/server select, geo +
  ping, speedtest and server add/edit/delete right inside the stock GL UI. The
  tab is creds-free (status is derived dynamically from the active server file;
  the view is UI-only). Detection is by presence of `/usr/lib/oui-httpd/rpc`,
  `/usr/share/oui/menu.d` and `/www/views`; if absent the tab is skipped. *The
  tab's exact look may vary slightly across devices / GL UI versions.*
- **GL.iNet fw 3.x (e.g. Mudi):** no SDK4 UI, so **no native tab** — but the
  bundled **web control panel** at `http://<router-ip>:8088` gives you a full
  browser UI (add/manage servers, on/off, kill-switch). SSH (`add-server.sh` /
  `list-servers.sh` / `del-server.sh`) and the sing-box **clash-api**
  (`127.0.0.1:9090`) remain available as fallbacks.
- **Firewall:** both backends are handled. On **fw3 (iptables)** `postup.sh`
  installs FORWARD + MASQUERADE (re-applied from cron). On **fw4 (nftables)** the
  installer drops a hotplug-firewall hook that re-adds the LAN→tunnel forwarding
  into the `inet fw4` table on every reload (idempotent, survives reboots). In
  both cases sing-box `auto_route` already tunnels the router's own traffic.
- Install survives firmware upgrades via `/etc/sysupgrade.conf`.

## Security note

**No credentials are in this repo.** No server IPs, UUIDs, Reality keys, short
IDs, passwords or share-links — you bring your own self-hosted server. The
sing-box binary is downloaded from the official SagerNet release at install
time (not bundled), and the installer `file`-verifies it matches your arch.

## What's in here

```
install.sh          arch-detect + download sing-box + set up service/cron
rebuild.sh          (re)generate sing-box config from servers/ (sing-box >=1.12 DNS schema)
parse-link.sh       share-link -> sing-box outbound JSON (vless+reality / hysteria2)
add-server.sh       add a server from a share-link, then rebuild
list-servers.sh     list configured servers (no secrets dumped)
del-server.sh       remove a server, then rebuild
postup.sh           LAN-client routing (iptables FORWARD + MASQUERADE, idempotent)
watchdog.sh         auto-stop sing-box if the router loses internet
geo-refresh.sh      cache egress IP / geo / ping for a status header
servers/            YOUR servers (ships EMPTY) + README + server.example.json
panel/              web control panel (:8088): index.html + api (CGI) + vpn-panel.init
sdk4-tab/           GL fw 4.x native VPN->Reality menu tab (deployed only if SDK4 detected):
                      reality.menu.json (menu entry), gl-sdk4-ui-reality.common.js (Vue view; installer gzips it for nginx),
                      reality.oui.lua (oui-httpd rpc backend), reality.validator.lua (arg validator)
LICENSE             MIT
```

## License

MIT — see [LICENSE](LICENSE).
