# Fixing `Latest: unknown`

Version 2.0.0-beta.2 fixes update checks that returned no version in GL SDK4:

- Read the installed version in Lua instead of a shell pipeline.
- Capture the version-check helper's JSON as a single command through OpenResty.
  No external `timeout` executable is required by the new RPC adapter.
- Try IPv4 HTTPS against the raw VERSION file, then the GitHub Contents API with
  its raw media type. If the VPN is enabled, also try the local SOCKS proxy.
- Validate the returned version; HTML/error pages are never update targets.
- Display an actionable failure message and allow **Install latest** when checking
  fails. An error is not displayed as **Up to date**.

No certificate checks are disabled. The helper records the source and HTTP status
of each attempt. Its requests are bounded to five seconds each.

## One-time recovery on an older installed version

Publishing new code cannot replace the old checker already on the router. If it
still shows `unknown` and hides Update, connect to the router over SSH and run:

```sh
cd /tmp && curl -fL --connect-timeout 10 --max-time 120 https://github.com/mxt96/reality-vpn-glinet-universal/archive/refs/heads/main.tar.gz -o singbox-update.tar.gz && tar xzf singbox-update.tar.gz && sh reality-vpn-glinet-universal-main/install.sh
```

This downloads from `github.com` without consulting the broken version endpoint.
The installer preserves existing servers, subscriptions, favorites and settings.
It restarts VPN services. Let it finish before refreshing the browser.

Afterward `/etc/sing-box/version` should show `2.0.0-beta.2` or a later version.
Open **Advanced → Software updates → Check for updates** again. If it still fails,
the UI now describes the failure instead of silently showing an unknown version.
For source/HTTP diagnostics, run:

```sh
lua /etc/sing-box/check-update.lua
```

If the SSH download itself fails, retain the curl error text: a blocked GitHub
connection, router clock/certificate issue, or DNS failure must be resolved first.

## Verification

`python3 tests/update_regressions.py` tests direct success, blocked raw host,
GitHub API fallback, invalid/HTML responses, optional VPN proxy, missing installed
marker, matching versions, prerelease/build versions and GL pipeline-output loss.
The browser suite checks failure display, manual install and recovery after retry.
Live checks validated both the raw URL and GitHub API raw response format.
