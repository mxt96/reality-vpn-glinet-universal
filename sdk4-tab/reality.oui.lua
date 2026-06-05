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
    return trim(sh("curl -s --max-time 3 " .. CLASH .. "/proxies/" .. sel ..
        " 2>/dev/null | sed -n 's/.*\"now\": *\"\\([A-Za-z0-9._-]*\\)\".*/\\1/p'"))
end

-- ---- status -------------------------------------------------------------
local function compute_status(args)
    -- toggle reflects DESIRED state (sticky through auto-reconnect); the live tunnel
    -- is conveyed by `active`/egress below. KS reflects user intent.
    local vpn = trim(sh("[ \"$(cat /etc/sing-box/vpn.enabled 2>/dev/null)\" = \"1\" ] && echo true || echo false"))
    local ks  = trim(sh(". /etc/sing-box/ks-lib.sh 2>/dev/null; ks_desired && echo true || echo false"))
    local mode = now_of("select")
    local active = mode
    if mode == "auto" then active = now_of("auto") end

    local g = trim(sh("cat /tmp/lk-geo 2>/dev/null"))
    local parts = {}
    for f in (g .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = f end
    local egress, country, city, ping = parts[2] or "", parts[3] or "", parts[4] or "", parts[5] or ""
    if g == "" then sh("(/etc/sing-box/geo-refresh.sh &) >/dev/null 2>&1") end

    -- Derive server + protocol from the ACTUALLY active outbound (no hardcoding),
    -- so the status matches whatever protocol the selector is using right now.
    local server, protocol = "", ""
    if active ~= "" and active ~= "direct" then
        local sf = io.open(SERVERS .. "/" .. active .. ".json", "r")
        if sf then
            local c = sf:read("*a"); sf:close()
            server = c:match('"server":%s*"([^"]*)"') or ""
            local ty = c:match('"type":%s*"([^"]*)"') or ""
            if ty == "vless" then protocol = "VLESS + Reality"
            elseif ty == "hysteria2" then protocol = "Hysteria2"
            elseif ty ~= "" then protocol = ty end
        end
    end

    return {
        running = (vpn == "true"),
        killswitch = (ks == "true"),
        mode = mode,
        active = active,
        egress = egress,
        country = country,
        city = city,
        ping = ping,
        server = server,
        protocol = protocol
    }
end

-- Never let a runtime error escape get_status: the SPA's global RPC interceptor
-- treats ANY error reply as a dead session and bounces the admin to /#/login.
-- pcall-guard + always return a valid (possibly degraded) status table instead.
function M.get_status(args)
    local ok, res = pcall(compute_status, args)
    if ok and type(res) == "table" then return res end
    return {
        running = false, killswitch = false, mode = "", active = "",
        egress = "", country = "", city = "", ping = "",
        server = "", protocol = ""
    }
end

-- ---- protocol selector --------------------------------------------------
function M.set_proto(args)
    local p = args and args.proto or ""
    if not (p == "auto" or p == "hy2-out" or p == "reality-out" or p:match("^srv%-[%w._%-]+$")) then
        return { ok = false, msg = "bad proto" }
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
    local out = trim(sh([[L=""; for f in /etc/sing-box/servers/*.json; do [ -f "$f" ] || continue; ]] ..
        [[t=$(basename "$f" .json); ty=$(sed -n 's/.*"type": *"\([a-z0-9]*\)".*/\1/p' "$f"|head -1); ]] ..
        [[sv=$(sed -n 's/.*"server": *"\([^"]*\)".*/\1/p' "$f"|head -1); ]] ..
        [[L="$L,{\"tag\":\"$t\",\"type\":\"$ty\",\"server\":\"$sv\"}"; done; echo "[${L#,}]"]]))
    local ok, arr = pcall(cjson.decode, out)
    if ok and type(arr) == "table" then return { servers = arr } end
    return { servers = {} }
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

function M.del_server(args)
    local tag = args and args.tag or ""
    if not tag:match("^srv%-[%w._%-]+$") then return { ok = false, msg = "bad tag" } end
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
    if not tag:match("^srv%-[%w._%-]+$") then return { ok = false, msg = "bad tag" } end
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

return M