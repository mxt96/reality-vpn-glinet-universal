--[[
    @object-name: reality
    @object-desc: Self-hosted Reality / Hysteria2 (sing-box) VPN control
--]]

local cjson = require "cjson"

local M = {}

local CLASH = "http://127.0.0.1:9090"
local SERVERS = "/etc/sing-box/servers"

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Non-blocking shell exec via OpenResty pipe (cooperative, yields to event loop).
local function sh(cmd, timeout)
    local argv
    if timeout then
        argv = { "timeout", tostring(timeout), "sh", "-c", cmd }
    else
        argv = { "sh", "-c", cmd }
    end
    local p = ngx.pipe.spawn(argv)
    if not p then return "" end
    if timeout then pcall(function() p:set_timeouts(nil, (tonumber(timeout) + 2) * 1000, nil) end) end
    local data = p:stdout_read_all()
    return data or ""
end

local function now_of(sel)
    -- Fetch raw JSON and parse in Lua. Do NOT pipe through sed: under oui-httpd's
    -- ngx.pipe.spawn a shell pipeline (`curl | sed`) returns EMPTY (only a single
    -- command's stdout is captured reliably), which silently blanked mode/active/
    -- egress/server in get_status -> the panel showed "—" + a false "no server
    -- selected" banner even while the tunnel was actually up. Same single-command
    -- pattern as get_traffic, which works.
    local out = sh("curl -s --max-time 3 " .. CLASH .. "/proxies/" .. sel .. " 2>/dev/null")
    return trim(out:match('"now"%s*:%s*"([A-Za-z0-9._%-]+)"') or "")
end

-- ---- status -------------------------------------------------------------
-- Pure parser (NO yields/shell here) — safe to run inside pcall. Takes the raw
-- strings already read by the caller and turns them into the status table.
local function parse_status(vpn, ks, sel, active, geo, srvjson)
    local parts = {}
    for f in ((geo or "") .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = f end
    local egress, country, city, ping = parts[2] or "", parts[3] or "", parts[4] or "", parts[5] or ""
    local server, protocol = "", ""
    if srvjson and srvjson ~= "" then
        server = srvjson:match('"server":%s*"([^"]*)"') or ""
        local ty = srvjson:match('"type":%s*"([^"]*)"') or ""
        if ty == "vless" then protocol = "VLESS + Reality"
        elseif ty == "hysteria2" then protocol = "Hysteria2"
        elseif ty ~= "" then protocol = ty end
    end
    return {
        running = (vpn == "true"), killswitch = (ks == "true"),
        mode = sel, active = active,
        egress = egress, country = country, city = city, ping = ping,
        server = server, protocol = protocol
    }
end

-- Never let a runtime error escape get_status: the SPA's global RPC interceptor
-- treats ANY error reply as a dead session and bounces the admin to /#/login.
-- CRITICAL: do ALL shell reads (sh() -> ngx.pipe YIELDS to the event loop) BEFORE
-- the pcall. You cannot yield across a pcall/C-call boundary in LuaJIT — doing the
-- yielding reads inside pcall raised "attempt to yield across C-call boundary",
-- pcall caught it, and get_status silently returned the blank fallback => the panel
-- showed "—" everywhere + a false "no server selected" banner even with the tunnel
-- UP. So: yielding reads here, pure parsing under pcall.
function M.get_status(args)
    local vpn = trim(sh("[ \"$(cat /etc/sing-box/vpn.enabled 2>/dev/null)\" = \"1\" ] && echo true || echo false"))
    local ks  = trim(sh(". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_desired && echo true || echo false"))
    local sel = now_of("select")
    local active = sel
    if sel == "auto" or sel == "auto-reality" or sel == "auto-hy2" then active = now_of(sel) end
    local geo = trim(sh("cat /tmp/lk-geo 2>/dev/null"))
    if geo == "" then sh("(/etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1") end
    local srvjson = ""
    if active ~= "" and active ~= "direct" then
        srvjson = trim(sh("cat " .. SERVERS .. "/" .. active .. ".json 2>/dev/null"))
    end
    local ok, res = pcall(parse_status, vpn, ks, sel, active, geo, srvjson)
    if ok and type(res) == "table" then return res end
    return {
        running = (vpn == "true"), killswitch = (ks == "true"), mode = "", active = "",
        egress = "", country = "", city = "", ping = "",
        server = "", protocol = ""
    }
end

-- ---- live traffic -------------------------------------------------------
-- One cheap clash call so the UI can poll every couple seconds and SHOW that
-- data is actually flowing through the tunnel (= the connection is real/alive),
-- plus cumulative totals since sing-box started. up_total/down_total are bytes;
-- the UI derives live speed from the delta between polls.
function M.get_traffic(args)
    local out = trim(sh("curl -s --max-time 3 " .. CLASH .. "/connections 2>/dev/null"))
    local up = tonumber(out:match('"uploadTotal"%s*:%s*(%-?%d+)')) or 0
    local down = tonumber(out:match('"downloadTotal"%s*:%s*(%-?%d+)')) or 0
    local conns = 0
    for _ in out:gmatch('"id"%s*:') do conns = conns + 1 end
    return { up_total = up, down_total = down, conns = conns }
end

-- ---- protocol selector --------------------------------------------------
function M.set_proto(args)
    local p = args and args.proto or ""
    -- Only "auto" or a real server tag map to an existing outbound. Legacy/phantom
    -- names (hy2-out, reality-out) have NO matching outbound in the universal config,
    -- so selecting them blackholes traffic and, with killswitch on, kills internet.
    -- Validate against the live servers dir; fall back to "auto" so we never select
    -- a non-existent node.
    if p == "auto-reality" or p == "auto-hy2" or p == "auto-fav" then
        -- protocol-filtered auto groups: rebuild.sh builds them only when servers of
        -- that family exist. Fall back to plain "auto" if the group isn't in the config.
        if trim(sh("grep -q '\"tag\": \"" .. p .. "\"' /etc/sing-box/reality_full.json 2>/dev/null && echo y || echo n")) ~= "y" then
            p = "auto"
        end
    elseif p ~= "auto" then
        if not p:match("^[%w][%w._%-]*$") then
            p = "auto"
        elseif trim(sh("[ -f /etc/sing-box/servers/" .. p .. ".json ] && echo y || echo n")) ~= "y" then
            p = "auto"
        end
    end
    sh("curl -s --max-time 4 -X PUT " .. CLASH .. "/proxies/select -d '{\"name\":\"" .. p ..
        "\"}' >/dev/null 2>&1; (sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    return { ok = true, mode = p }
end

-- ---- on / off -----------------------------------------------------------
function M.set_enabled(args)
    local on = args and args.on
    if on == true or on == "true" or on == 1 then
        -- persist desired=ON so the supervisor keeps the tunnel up / auto-reconnects
        sh("echo 1 > /etc/sing-box/vpn.enabled; " ..
           "/etc/init.d/sing-box start >/dev/null 2>&1; sleep 1; " ..
           "[ -f /etc/sing-box/postup.sh ] && sh /etc/sing-box/postup.sh >/dev/null 2>&1; " ..
           ". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_enforce; " ..
           "(/etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1", 20)
    else
        -- persist desired=OFF; ks_enforce releases the killswitch block (can't strand)
        sh("echo 0 > /etc/sing-box/vpn.enabled; " ..
           "/etc/init.d/sing-box stop >/dev/null 2>&1; killall sing-box >/dev/null 2>&1; " ..
           "ip rule del pref 500 >/dev/null 2>&1; " ..
           ". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_enforce; " ..
           "(sleep 3; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1", 15)
    end
    return { ok = true }
end

-- ---- killswitch ---------------------------------------------------------
function M.set_killswitch(args)
    local on = args and args.on
    -- backend-aware (fw4/nftables vs fw3/iptables) + desired-state via ks-lib.sh;
    -- ks_set_desired also mirrors into GL's native killswitch uci for UI sync.
    if on == true or on == "true" or on == 1 then
        sh(". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_set_desired 1; ks_enforce")
    else
        sh(". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_set_desired 0; ks_enforce")
    end
    return { ok = true }
end

-- ---- servers ------------------------------------------------------------
function M.list_servers(args)
    -- fam = protocol family for the UI filter (reality / tls / trojan / shadowsocks /
    -- hysteria2). vless splits on Reality presence: a "reality" block in the json => the
    -- DPI-resistant Reality transport, otherwise plain VLESS-over-TLS. busybox-safe sh.
    local out = trim(sh([[L=""; FAVF=/etc/sing-box/favorites; for f in /etc/sing-box/servers/*.json; do [ -f "$f" ] || continue; ]] ..
        [[t=$(basename "$f" .json); ty=$(sed -n 's/.*"type": *"\([a-z0-9]*\)".*/\1/p' "$f"|head -1); ]] ..
        [[sv=$(sed -n 's/.*"server": *"\([^"]*\)".*/\1/p' "$f"|head -1); ]] ..
        [[fam="$ty"; case "$ty" in vless) if grep -q '"reality"' "$f"; then fam=reality; else fam=tls; fi;; esac; ]] ..
        [[fv=false; [ -f "$FAVF" ] && grep -qxF "$t" "$FAVF" && fv=true; ]] ..
        [[L="$L,{\"tag\":\"$t\",\"type\":\"$ty\",\"fam\":\"$fam\",\"server\":\"$sv\",\"fav\":$fv}"; done; echo "[${L#,}]"]]))
    local ok, arr = pcall(cjson.decode, out)
    if ok and type(arr) == "table" then return { servers = arr } end
    return { servers = {} }
end

-- ---- favorites: star servers; "Auto ★" urltests ONLY these --------------
function M.get_fav(args)
    local out = trim(sh("[ -f /etc/sing-box/favorites ] && grep -v '^$' /etc/sing-box/favorites || true"))
    local list = {}
    for line in out:gmatch("[^\r\n]+") do list[#list+1] = line end
    return { fav = list }
end

function M.set_fav(args)
    local tag = args and args.tag or ""
    local on = args and (args.on == true or args.on == "true" or args.on == 1 or args.on == "1")
    if not tag:match("^[%w][%w._%-]*$") then return { ok = false, msg = "bad tag" } end
    if on then
        sh("touch /etc/sing-box/favorites; grep -qxF '" .. tag .. "' /etc/sing-box/favorites || echo '" .. tag .. "' >> /etc/sing-box/favorites")
    else
        sh("[ -f /etc/sing-box/favorites ] && grep -vxF '" .. tag .. "' /etc/sing-box/favorites > /etc/sing-box/favorites.tmp 2>/dev/null && mv /etc/sing-box/favorites.tmp /etc/sing-box/favorites")
    end
    -- rebuild so the auto-fav urltest pool reflects the change; reload sing-box if running
    sh("sh /etc/sing-box/rebuild.sh >/dev/null 2>&1; [ \"$(cat /etc/sing-box/vpn.enabled 2>/dev/null)\" = 1 ] && /etc/init.d/sing-box restart >/dev/null 2>&1", 20)
    return { ok = true }
end

-- Bulk star/unstar — set the whole "Auto ★" pool from the UI's filtered set in ONE
-- shot (e.g. "★ all shown" after a search/protocol filter). Writes favorites once and
-- rebuilds once, instead of N rebuilds — essential with 100+ subscription servers.
function M.set_fav_bulk(args)
    local tags = args and args.tags or {}
    local on = args and (args.on == true or args.on == "true" or args.on == 1 or args.on == "1")
    if type(tags) ~= "table" then return { ok = false, msg = "bad tags" } end
    local clean = {}
    for _, tg in ipairs(tags) do
        if type(tg) == "string" and tg:match("^[%w][%w._%-]*$") then clean[#clean + 1] = tg end
    end
    if #clean == 0 then return { ok = false, msg = "no valid tags" } end
    -- tags are filename-safe (alnum . _ -) so they're safe to pass unquoted into sh.
    local list = table.concat(clean, " ")
    sh("F=/etc/sing-box/favorites; touch \"$F\"; T=/tmp/fav-batch.$$; : > \"$T\"; for x in " .. list ..
       "; do echo \"$x\" >> \"$T\"; done; " ..
       (on and "sort -u \"$F\" \"$T\" -o \"$F\""
            or "grep -vxF -f \"$T\" \"$F\" > \"$F.tmp\" 2>/dev/null && mv \"$F.tmp\" \"$F\""
       ) .. "; rm -f \"$T\"")
    sh("sh /etc/sing-box/rebuild.sh >/dev/null 2>&1; [ \"$(cat /etc/sing-box/vpn.enabled 2>/dev/null)\" = 1 ] && /etc/init.d/sing-box restart >/dev/null 2>&1", 25)
    return { ok = true, n = #clean }
end

-- Per-server latency (Happ-style ping). Asks sing-box's Clash API to measure each
-- outbound's real handshake delay against generate_204. Returns {pings:{tag:ms}};
-- ms = -1 means the node failed/timed out. No flags/images — just numbers, so the
-- installer stays tiny (mason: keep it light for the Mudi).
function M.ping_servers(args)
    local out = trim(sh([[R=""; for f in /etc/sing-box/servers/*.json; do [ -f "$f" ] || continue; ]] ..
        [[t=$(basename "$f" .json); ]] ..
        [[d=$(curl -s --max-time 5 "]] .. CLASH .. [[/proxies/$t/delay?timeout=3000&url=http://www.gstatic.com/generate_204" 2>/dev/null); ]] ..
        [[ms=$(echo "$d" | sed -n 's/.*"delay":[ ]*\([0-9][0-9]*\).*/\1/p'); [ -z "$ms" ] && ms=-1; ]] ..
        [[R="$R,\"$t\":$ms"; done; echo "{${R#,}}"]], 40))
    local ok, m = pcall(cjson.decode, out)
    if ok and type(m) == "table" then return { pings = m } end
    return { pings = {} }
end

function M.add_server(args)
    local link = args and args.link or ""
    local name = args and args.name or ""
    if link == "" then return { ok = false, msg = "Empty link" } end
    local tag
    if name ~= "" then tag = "srv-" .. name:gsub("[^%w._%-]", "_") else tag = "srv-" .. tostring(ngx.time()) end

    -- write the share-link to a temp file (avoids shell-quoting / injection on the URL)
    local tf = io.open("/tmp/reality-addlink", "w")
    if not tf then return { ok = false, msg = "io error" } end
    tf:write(link); tf:close()

    local parsed = trim(sh('/etc/sing-box/parse-link.sh "$(cat /tmp/reality-addlink)" ' .. tag .. ' 2>/tmp/reality-perr'))
    if parsed == "" then
        local reason = trim(sh("cat /tmp/reality-perr 2>/dev/null"))
        return { ok = false, msg = reason ~= "" and ("Bad link: " .. reason) or "Unrecognized link" }
    end
    local sf = io.open(SERVERS .. "/" .. tag .. ".json", "w")
    if not sf then return { ok = false, msg = "io error" } end
    sf:write(parsed); sf:close()

    local r = trim(sh("/etc/sing-box/rebuild.sh 2>/dev/null | head -1"))
    if r == "OK" then
        return { ok = true, tag = tag }
    else
        os.remove(SERVERS .. "/" .. tag .. ".json")
        sh("/etc/sing-box/rebuild.sh >/dev/null 2>&1")
        return { ok = false, msg = "Server config rejected" }
    end
end

-- Bulk import (Shadowrocket-style): args.text may be many share-links (one per
-- line), a base64 subscription blob, or an http(s):// subscription URL. Each link
-- is parsed + written and the config is rebuilt ONCE. Returns {ok,added,failed,tags}.
function M.import_links(args)
    local text = args and args.text or ""
    if text == "" then return { ok = false, msg = "Empty input" } end
    local tf = io.open("/tmp/reality-import", "w")
    if not tf then return { ok = false, msg = "io error" } end
    tf:write(text); tf:close()
    local out = trim(sh("/etc/sing-box/import-links.sh < /tmp/reality-import 2>/dev/null", 60))
    sh("(sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    local ok, res = pcall(cjson.decode, out)
    if ok and type(res) == "table" then return res end
    return { ok = false, msg = "import failed" }
end

-- ---- subscriptions (Happ-style saved + auto-updating) -------------------
-- Stored subscription URLs that the panel/cron re-pulls so the server list stays
-- in sync (new servers added, vanished ones removed). Backed by sub-store.sh.
local SUBSTORE = "/etc/sing-box/sub-store.sh"

function M.list_subs(args)
    local out = trim(sh("sh " .. SUBSTORE .. " list 2>/dev/null"))
    local ok, res = pcall(cjson.decode, out)
    if ok and type(res) == "table" then return res end
    return { subs = {} }
end

function M.add_sub(args)
    local url = args and args.url or ""
    local name = args and args.name or ""
    if url == "" then return { ok = false, msg = "Empty URL" } end
    -- write url/name to temp files (avoids shell-quoting / injection on the URL)
    local uf = io.open("/tmp/reality-suburl", "w")
    if not uf then return { ok = false, msg = "io error" } end
    uf:write(url); uf:close()
    local nf = io.open("/tmp/reality-subname", "w")
    if nf then nf:write(name); nf:close() end
    local out = trim(sh("sh " .. SUBSTORE ..
        " add \"$(cat /tmp/reality-suburl)\" \"$(cat /tmp/reality-subname 2>/dev/null)\" 2>/dev/null", 60))
    sh("(sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    local ok, res = pcall(cjson.decode, out)
    if ok and type(res) == "table" then return res end
    return { ok = false, msg = "add failed" }
end

function M.del_sub(args)
    local id = args and args.id or ""
    if not id:match("^[%w][%w._%-]*$") then return { ok = false, msg = "bad id" } end
    local out = trim(sh("sh " .. SUBSTORE .. " del " .. id .. " 2>/dev/null", 30))
    sh("(sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    local ok, res = pcall(cjson.decode, out)
    if ok and type(res) == "table" then return res end
    return { ok = false, msg = "delete failed" }
end

function M.refresh_subs(args)
    local id = args and args.id or "all"
    if id ~= "all" and not id:match("^[%w][%w._%-]*$") then id = "all" end
    local out = trim(sh("sh " .. SUBSTORE .. " refresh " .. id .. " 2>/dev/null", 60))
    sh("(sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    local ok, res = pcall(cjson.decode, out)
    if ok and type(res) == "table" then return res end
    return { ok = false, msg = "refresh failed" }
end

function M.del_server(args)
    local tag = args and args.tag or ""
    if not tag:match("^[%w][%w._%-]*$") then return { ok = false, msg = "bad tag" } end
    -- If deleting the currently-selected server, fall back to "auto" first so the
    -- tunnel keeps running on the base outbounds instead of breaking. (mason: safe
    -- delete of the active config.)
    local cur = now_of("select")
    local was_active = (cur == tag)
    if was_active then
        sh("curl -s --max-time 4 -X PUT " .. CLASH .. "/proxies/select -d '{\"name\":\"auto\"}' >/dev/null 2>&1")
    end
    os.remove(SERVERS .. "/" .. tag .. ".json")
    sh("/etc/sing-box/rebuild.sh >/dev/null 2>&1; (sleep 2; /etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1")
    return { ok = true, was_active = was_active }
end

-- Edit a server: replace its share-link (and optionally rename). The original
-- share-link isn't stored (only the parsed outbound), so the UI asks for a fresh
-- link. Re-parses, swaps the file, rebuilds; rolls back on a rejected config.
function M.edit_server(args)
    local tag     = args and args.tag or ""
    local link    = args and args.link or ""
    local newname = args and args.name or ""
    if not tag:match("^[%w][%w._%-]*$") then return { ok = false, msg = "bad tag" } end
    if link == "" then return { ok = false, msg = "Empty link" } end

    local oldfile = SERVERS .. "/" .. tag .. ".json"
    local ef = io.open(oldfile, "r")
    if not ef then return { ok = false, msg = "Server not found" } end
    local oldcontent = ef:read("*a"); ef:close()

    local newtag = tag
    if newname ~= "" then newtag = "srv-" .. newname:gsub("[^%w._%-]", "_") end

    local tf = io.open("/tmp/reality-editlink", "w")
    if not tf then return { ok = false, msg = "io error" } end
    tf:write(link); tf:close()

    local parsed = trim(sh('/etc/sing-box/parse-link.sh "$(cat /tmp/reality-editlink)" ' .. newtag .. ' 2>/dev/null'))
    if parsed == "" then
        return { ok = false, msg = "Unrecognized link (vless reality / hysteria2)" }
    end

    local sf = io.open(SERVERS .. "/" .. newtag .. ".json", "w")
    if not sf then return { ok = false, msg = "io error" } end
    sf:write(parsed); sf:close()
    if newtag ~= tag then os.remove(oldfile) end

    local r = trim(sh("/etc/sing-box/rebuild.sh 2>/dev/null | head -1"))
    if r == "OK" then
        return { ok = true, tag = newtag }
    else
        -- rollback to the previous server file
        if newtag ~= tag then os.remove(SERVERS .. "/" .. newtag .. ".json") end
        local rb = io.open(oldfile, "w")
        if rb then rb:write(oldcontent); rb:close() end
        sh("/etc/sing-box/rebuild.sh >/dev/null 2>&1")
        return { ok = false, msg = "Server config rejected" }
    end
end

-- ---- speedtest ----------------------------------------------------------
function M.speedtest(args)
    local db = trim(sh("curl -4 -s --max-time 12 -o /dev/null -w '%{speed_download}' " ..
        "'https://speed.cloudflare.com/__down?bytes=30000000' 2>/dev/null", 15))
    local ub = trim(sh("head -c 8000000 /dev/zero 2>/dev/null | curl -4 -s --max-time 12 -o /dev/null " ..
        "-w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up' 2>/dev/null", 15))
    local dn = tonumber(db) or 0
    local up = tonumber(ub) or 0
    return {
        down = string.format("%.1f", dn * 8 / 1000000),
        up = string.format("%.1f", up * 8 / 1000000)
    }
end

-- ---- version / self-update ----------------------------------------------
-- Mirrors the standalone :8088 panel's checkupdate/update so the native GL tab
-- can show the installed version and update in place from GitHub.
local REPO = "mxt96/reality-vpn-glinet-universal"

function M.check_update(args)
    local inst = trim(sh("cat /etc/sing-box/version 2>/dev/null | tr -d ' \\r\\n'"))
    if inst == "" then inst = "unknown" end
    local lat = trim(sh("curl -fsSL --max-time 8 https://raw.githubusercontent.com/" ..
        REPO .. "/main/VERSION 2>/dev/null | tr -d ' \\r\\n'", 10))
    if lat == "" then lat = "unknown" end
    return { installed = inst, latest = lat, update = (lat ~= "unknown" and inst ~= lat) }
end

function M.do_update(args)
    -- Re-running the installer restarts services (incl. oui-httpd's own tree), so it
    -- must NOT run inside this request. Detach via the router's cron — a one-shot,
    -- lock-guarded, self-removing line — exactly like the :8088 panel's update path.
    local script = [[#!/bin/sh
[ -f /tmp/sb-update.running ] && exit 0
touch /tmp/sb-update.running
# sync the clock FIRST — if the router's time is wrong (drifts after a reboot, weak NTP)
# curl rejects GitHub's TLS cert as "not yet valid" and the download fails. NTP is UDP/no
# cert so it works regardless of the current clock.
ntpd -nq -p time.google.com >/dev/null 2>&1 || ntpd -nq -p pool.ntp.org >/dev/null 2>&1 || true
cd /tmp && rm -rf reality-vpn-glinet-universal-main \
  && curl -fsSL https://github.com/mxt96/reality-vpn-glinet-universal/archive/refs/heads/main.tar.gz | tar xz \
  && cd reality-vpn-glinet-universal-main && sh install.sh
sed -i '\#/tmp/sb-update.sh#d' /etc/crontabs/root 2>/dev/null
/etc/init.d/cron restart 2>/dev/null
rm -f /tmp/sb-update.running
]]
    local f = io.open("/tmp/sb-update.sh", "w")
    if not f then return { ok = false, msg = "io error" } end
    f:write(script); f:close()
    sh("chmod +x /tmp/sb-update.sh; touch /etc/crontabs/root; " ..
       "grep -q '/tmp/sb-update.sh' /etc/crontabs/root 2>/dev/null || " ..
       "echo '* * * * * /bin/sh /tmp/sb-update.sh' >> /etc/crontabs/root; " ..
       "/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron restart >/dev/null 2>&1")
    return { ok = true, msg = "Update scheduled — installs within ~1-2 min, page reloads" }
end

-- WAN MAC privacy removed 2026-06-20: GL.iNet's newer firmware ships a native
-- "random MAC" setting, so the panel's own MAC tool was redundant.

return M