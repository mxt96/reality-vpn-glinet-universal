#!/usr/bin/lua
-- Run outside OpenResty's event loop. Keep curl output out of shell pipelines:
-- GL SDK4 can return empty pipeline stdout through ngx.pipe on some firmware.
local json = require 'cjson'
local D = os.getenv('SBDIR') or '/etc/sing-box'
local REPO = 'mxt96/reality-vpn-glinet-universal'
local function read(path)
    local f=io.open(path); if not f then return '' end
    local value=f:read('*a'); f:close(); return value
end
local function trim(s) return (s or ''):gsub('^%s+',''):gsub('%s+$','') end
local function version(s)
    s=trim(s):gsub('^v','')
    if #s>64 then return nil end
    local base,suffix=s:match('^(%d+%.%d+%.%d+)(.*)$')
    if base and (suffix=='' or suffix:match('^[-+][%w][%w.+%-]*$')) then return s end
end
local function quote(s) return "'"..s:gsub("'", "'\\''").."'" end
local attempts={}
local function fetch(source,url,via_proxy)
    local args={'curl','-4','-fsSL','--connect-timeout','2','--max-time','5',
        '-H','Accept: application/vnd.github.raw+json','-H','Cache-Control: no-cache',
        '-w',string.char(10)..'__SB_UPDATE_HTTP:%{http_code}'}
    if via_proxy then args[#args+1]='--proxy'; args[#args+1]='socks5h://127.0.0.1:2080'; args[#args+1]='--noproxy'; args[#args+1]='' end
    args[#args+1]=url
    local escaped={}; for _,value in ipairs(args) do escaped[#escaped+1]=quote(value) end
    local p=io.popen(table.concat(escaped,' ')..' 2>/dev/null')
    local raw=p and p:read('*a') or ''; if p then p:close() end
    local body,http=raw:match('^(.*)\n__SB_UPDATE_HTTP:(%d%d%d)%s*$')
    local latest=body and tonumber(http)==200 and version(body) or nil
    attempts[#attempts+1]={source=source,http_status=tonumber(http) or 0,valid=latest~=nil}
    return latest
end
local timestamp=tostring(os.time())
local raw='https://raw.githubusercontent.com/'..REPO..'/main/VERSION?check='..timestamp
local api='https://api.github.com/repos/'..REPO..'/contents/VERSION?ref=main&check='..timestamp
local installed=version(read(D..'/version')) or 'unknown'
local latest=fetch('raw-ipv4',raw,false) or fetch('github-api-ipv4',api,false)
if not latest and trim(read(D..'/vpn.enabled'))=='1' then latest=fetch('vpn-proxy',raw,true) end
local result={installed=installed,latest=latest or 'unknown',update=latest~=nil and installed~=latest,attempts=attempts}
if latest then result.ok=true; result.source=attempts[#attempts].source
else
    result.ok=false; result.error='version_fetch_failed'
    result.msg='Could not fetch the latest version. Check router internet access, DNS, date/time and GitHub access. Retry or use Install latest.'
end
io.write(json.encode(result)..'\n')
