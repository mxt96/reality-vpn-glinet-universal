#!/usr/bin/lua
-- Shared backend for the GL SDK4 adapter and the standalone browser UI.
-- JSON is always handled by a parser; untrusted values never become shell code.
local json = require 'cjson'
local D = os.getenv('SBDIR') or '/etc/sing-box'
local API = os.getenv('SB_API') or 'http://127.0.0.1:9090'
local M = {}
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function command(args)
    local a = {}; for _, v in ipairs(args) do a[#a+1] = quote(v) end
    return table.concat(a, ' ')
end
local function run(args) return os.execute(command(args) .. ' >/dev/null 2>&1') == 0 end
local function read(path)
    local f = io.open(path); if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end
local function capture(args)
    local p = io.popen(command(args) .. ' 2>/dev/null'); if not p then return '' end
    local s = p:read('*a'); p:close(); return s or ''
end
local function decode(s, fallback)
    local ok, value = pcall(json.decode, s or '')
    return ok and value or fallback
end
local function atomic(path, value)
    local tmp = path .. '.new'
    local f = assert(io.open(tmp, 'w')); assert(f:write(value)); assert(f:close())
    assert(run({'chmod', '600', tmp}), 'Cannot protect configuration')
    assert(os.rename(tmp, path))
end
local function iface(s) return type(s)=='string' and #s<=15 and s:match('^[%w][%w_.%-]*$') end
local function tag(s) return type(s)=='string' and #s<=128 and s:match('^[%w][%w_.%-]*$') end
local function ipv4(s)
    if type(s)~='string' or not s:match('^%d+%.%d+%.%d+%.%d+$') then return false end
    for x in s:gmatch('%d+') do if tonumber(x)>255 then return false end end
    return true
end
local function trim(s) return (s or ''):gsub('^%s+',''):gsub('%s+$','') end
local defaults = {schema=1, default_route='sing-box', lan_interfaces={'br-lan'}, wan='wan',
    routing='all', domains={}, block_domains={}, dns='udp', dns_address='8.8.8.8',
    subscription_hours=6}
local function settings()
    local s = decode(read(D..'/settings.json'), {})
    for k,v in pairs(defaults) do if s[k]==nil then s[k]=v end end
    return s
end
local function policies() return decode(read(D..'/policies.json'), {}) end
local function wanted() return trim(read(D..'/vpn.enabled'))=='1' end
local function ready()
    if not run({'ip','link','show','singtun0'}) then return false end
    local v = decode(capture({'curl','--noproxy','*','-fsS','--max-time','2',API..'/version'}), {})
    return v.version~=nil
end
local function native()
    local dump = decode(capture({'ubus','call','network.interface','dump'}), {})
    return dump.interface or {}
end
local function wan(s)
    local all = native()
    for _,v in ipairs(all) do
        if v.interface==s.wan and v.up and iface(v.l3_device) then return v end
    end
    return nil -- fail closed instead of guessing another VPN's default route
end
local function tunnel(s)
    return iface(s) and (s:match('^wg') or s:match('^awg') or s:match('^tun') or s:match('^tap') or s:match('^ovpn'))
end
local function check_settings(s)
    assert(s.default_route=='sing-box' or s.default_route=='router','Invalid default route')
    assert(tag(s.wan), 'Invalid WAN network')
    assert(type(s.lan_interfaces)=='table' and #s.lan_interfaces>0 and #s.lan_interfaces<=8,'Choose local interfaces')
    for _,v in ipairs(s.lan_interfaces) do assert(iface(v) and not tunnel(v),'Invalid LAN interface') end
    assert(s.routing=='all' or s.routing=='include' or s.routing=='exclude','Invalid routing profile')
    for _,key in ipairs({'domains','block_domains'}) do
        assert(type(s[key])=='table' and #s[key]<=512,'Too many domains')
        for _,v in ipairs(s[key]) do assert(type(v)=='string' and #v<=253 and v:match('^[%w][%w.%-]*[%w]$') and not v:find('..',1,true),'Invalid domain') end
    end
    assert(s.dns=='udp' or s.dns=='https','Invalid DNS type')
    if s.dns=='udp' then assert(ipv4(s.dns_address),'DNS must be an IPv4 address')
    else assert(type(s.dns_address)=='string' and s.dns_address:match('^https://[%w.%-]+/[%w/%-_.?=&]*$'),'Invalid HTTPS DNS URL') end
    assert(type(s.subscription_hours)=='number' and s.subscription_hours>=1 and s.subscription_hours<=168 and s.subscription_hours%1==0,'Invalid update interval')
end
local function check_policy(p,s)
    assert(type(p)=='table','Invalid policy')
    p.source_interface=p.source_interface or 'br-lan'
    local local_if=false; for _,v in ipairs(s.lan_interfaces) do if v==p.source_interface then local_if=true end end
    assert(local_if,'Choose a configured local interface')
    if p.kind=='network' then p.id='network-'..p.source_interface; p.mac=nil
    else
        p.kind='device'; assert(type(p.mac)=='string' and p.mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$'),'Invalid MAC address')
        p.mac=p.mac:lower(); p.id='device-'..p.mac:gsub(':','')
    end
    assert(p.mode=='local-only' or p.mode=='direct' or p.mode=='sing-box' or p.mode=='interface' or p.mode=='inherit','Invalid policy mode')
    if p.mode=='interface' then assert(tunnel(p.interface),'Choose a WireGuard/OpenVPN interface') else p.interface=nil end
    p.name=type(p.name)=='string' and p.name:sub(1,64) or p.id
    return p
end
local function selector(p) -- iptables selector, already validated
    local a={'-i',p.source_interface}
    if p.mac then for _,v in ipairs({'-m','mac','--mac-source',p.mac}) do a[#a+1]=v end end
    return a
end
local function join(a,b)
    local r={}; for _,x in ipairs(a) do r[#r+1]=x end; for _,x in ipairs(b) do r[#r+1]=x end; return r
end
local function line(a) return table.concat(a,' ') end
local function active_iface(p,w)
    if p.mode=='direct' then return w and w.l3_device end
    if p.mode=='sing-box' then return wanted() and ready() and 'singtun0' or nil end
    if p.mode=='interface' and run({'ip','link','show',p.interface}) then return p.interface end
end
local function gateway(w,family)
    local routes={}
    for _,r in ipairs((w or {}).route or {}) do routes[#routes+1]=r end
    if family==6 and w then
        for _,v in ipairs(native()) do
            if v.up and v.l3_device==w.l3_device then for _,r in ipairs(v.route or {}) do routes[#routes+1]=r end end
        end
    end
    for _,r in ipairs(routes) do
        if r.mask==0 and type(r.nexthop)=='string' then
            if family==4 and ipv4(r.nexthop) then return r.nexthop end
            if family==6 and r.nexthop:match('^[%x:]+$') and r.nexthop:find(':') then return r.nexthop end
        end
    end
end
local function local_routes(s,tableid,family)
    for _,dev in ipairs(s.lan_interfaces) do
        local out=capture({'ip','-'..family,'route','show','dev',dev,'scope','link'})
        for row in out:gmatch('[^\n]+') do
            local dst=row:match('^([%x:./]+)')
            if dst and dst:find('/') then run({'ip','-'..family,'route','replace',dst,'dev',dev,'table',tableid}) end
        end
    end
end
local function route_table(s,p,w,id)
    local dev=active_iface(p,w)
    for _,family in ipairs({4,6}) do
        run({'ip','-'..family,'route','flush','table',id})
        -- A terminal route prevents fallback through another VPN or WAN.
        assert(run({'ip','-'..family,'route','add','unreachable','default','metric','32760','table',id}), 'Cannot install fail-closed route')
        local_routes(s,id,family)
        if dev then
            if p.mode=='direct' then
                local gw=gateway(w,family)
                if gw then
                    run({'ip','-'..family,'route','replace',gw..(family==4 and '/32' or '/128'),'dev',dev,'table',id})
                    run({'ip','-'..family,'route','add','default','via',gw,'dev',dev,'metric','10','table',id})
                elseif w and (w.proto=='pppoe' or w.proto=='ppp') then
                    run({'ip','-'..family,'route','add','default','dev',dev,'metric','10','table',id})
                end
            elseif family==4 or (dev~='singtun0' and capture({'ip','-6','addr','show','dev',dev,'scope','global'}):find('inet6')) then
                run({'ip','-'..family,'route','add','default','dev',dev,'metric','10','table',id})
            end
        end
    end
end
local function iptables_payload(s,ps,w,family,attach)
    local f={'*filter',':SB_POLICY -','-F SB_POLICY'}
    local m={'*mangle',':SB_MARK -','-F SB_MARK'}
    for i,p in ipairs(ps) do
        local sel=selector(p)
        for _,dev in ipairs(s.lan_interfaces) do f[#f+1]=line(join({'-A','SB_POLICY'},join(sel,{'-o',dev,'-j','ACCEPT'}))) end
        if p.mode~='local-only' then
            local dev=active_iface(p,w)
            if dev and (family==4 or dev~='singtun0') then
                f[#f+1]=line(join({'-A','SB_POLICY'},join(sel,{'-o',dev,'-j','ACCEPT'})))
            end
            m[#m+1]=line(join({'-A','SB_MARK'},join(sel,{'-j','MARK','--set-xmark',string.format('0x%x/0x00ff0000',i*65536)})))
            m[#m+1]=line(join({'-A','SB_MARK'},join(sel,{'-j','RETURN'})))
        end
        f[#f+1]=line(join({'-A','SB_POLICY'},join(sel,{'-j','DROP'})))
    end
    local protected=trim(read(D..'/ks.enabled'))=='1'
    local defaultvpn=wanted() and ready() and s.default_route=='sing-box'
    for _,src in ipairs(s.lan_interfaces) do
        for _,dst in ipairs(s.lan_interfaces) do f[#f+1]='-A SB_POLICY -i '..src..' -o '..dst..' -j RETURN' end
        if defaultvpn and family==4 then f[#f+1]='-A SB_POLICY -i '..src..' -o singtun0 -j ACCEPT' end
        if protected or (defaultvpn and family==6) then f[#f+1]='-A SB_POLICY -i '..src..' -j DROP' end
    end
    local bin=family==4 and 'iptables' or 'ip6tables'
    if attach then
        if run({bin,'-C','FORWARD','-j','SB_POLICY'}) then f[#f+1]='-D FORWARD -j SB_POLICY' end
        f[#f+1]='-I FORWARD 1 -j SB_POLICY'
    end
    if attach and not run({bin,'-t','mangle','-C','PREROUTING','-j','SB_MARK'}) then m[#m+1]='-A PREROUTING -j SB_MARK' end
    f[#f+1]='COMMIT'; m[#m+1]='COMMIT'
    return table.concat(f,'\n')..'\n'..table.concat(m,'\n')..'\n'
end
local function nft_payload(s,ps,w)
    local a={}
    if run({'nft','list','table','inet','sb_policy'}) then a[#a+1]='delete table inet sb_policy' end
    a[#a+1]='table inet sb_policy { chain policy_mark { type filter hook prerouting priority -140; policy accept;'
    for i,p in ipairs(ps) do
        if p.mode~='local-only' then
            local sel='iifname "'..p.source_interface..'"'..(p.mac and ' ether saddr '..p.mac or '')
            a[#a+1]=sel..string.format(' meta mark set (meta mark & 0xff00ffff) | 0x%x',i*65536)..' return'
        end
    end
    a[#a+1]='}\nchain guard { type filter hook forward priority -5; policy accept;'
    local allows={}
    for _,p in ipairs(ps) do
        local sel='iifname "'..p.source_interface..'"'..(p.mac and ' ether saddr '..p.mac or '')
        for _,dev in ipairs(s.lan_interfaces) do a[#a+1]=sel..' oifname "'..dev..'" accept' end
        local dev=active_iface(p,w)
        if dev and p.mode~='local-only' then
            a[#a+1]=sel..' oifname "'..dev..'" accept'
            allows[#allows+1]=sel..' oifname "'..dev..'" accept'
        end
        a[#a+1]=sel..' drop'
    end
    local protected=trim(read(D..'/ks.enabled'))=='1'
    local defaultvpn=wanted() and ready() and s.default_route=='sing-box'
    for _,src in ipairs(s.lan_interfaces) do
        for _,dst in ipairs(s.lan_interfaces) do a[#a+1]='iifname "'..src..'" oifname "'..dst..'" accept' end
        if defaultvpn then
            a[#a+1]='meta nfproto ipv4 iifname "'..src..'" oifname "singtun0" accept'
            allows[#allows+1]='meta nfproto ipv4 iifname "'..src..'" oifname "singtun0" accept'
        end
        if protected then a[#a+1]='iifname "'..src..'" drop'
        elseif defaultvpn then a[#a+1]='meta nfproto ipv6 iifname "'..src..'" drop' end
    end
    a[#a+1]='}\n}'
    if not run({'nft','list','chain','inet','fw4','SB_ACCEPT'}) then a[#a+1]='add chain inet fw4 SB_ACCEPT' end
    a[#a+1]='flush chain inet fw4 SB_ACCEPT'
    for _,v in ipairs(allows) do a[#a+1]='add rule inet fw4 SB_ACCEPT '..v end
    if not capture({'nft','list','chain','inet','fw4','forward'}):find('jump SB_ACCEPT',1,true) then a[#a+1]='insert rule inet fw4 forward jump SB_ACCEPT' end
    return table.concat(a,'\n')..'\n'
end
function M.apply(s,ps)
    s=s or settings(); ps=ps or policies(); check_settings(s)
    assert(#ps<=128,'Too many policies')
    for _,p in ipairs(ps) do check_policy(p,s) end
    table.sort(ps,function(a,b) if a.kind~=b.kind then return a.kind=='device' end; return a.id<b.id end)
    local w=wan(s)
    if #ps>0 then
        -- Existing accelerated flows bypass subsequent FORWARD checks. Keep the
        -- standard OpenWrt flowtable disabled while explicit policies exist.
        local changed=false
        for _,key in ipairs({'flow_offloading','flow_offloading_hw'}) do
            if trim(capture({'uci','-q','get','firewall.@defaults[0].'..key}))=='1' then
                assert(run({'uci','set','firewall.@defaults[0].'..key..'=0'}),'Cannot disable flow offloading')
                changed=true
            end
        end
        if changed then
            assert(run({'uci','commit','firewall'}),'Cannot save firewall settings')
            -- Re-entrant include is rejected by the lock; this invocation then
            -- installs the new policy guard synchronously before reporting OK.
            assert(run({'/etc/init.d/firewall','reload'}),'Cannot flush accelerated flows')
        end
    end
    -- Publish strict forwarding guards before installing routes/marks.
    if run({'nft','list','table','inet','fw4'}) then
        atomic(D..'/policy.nft',nft_payload(s,ps,w))
        assert(run({'nft','-c','-f',D..'/policy.nft'}),'Unsupported nftables rule')
        assert(run({'nft','-f',D..'/policy.nft'}),'Could not apply nftables policies')
    else
        for _,family in ipairs({4,6}) do
            local path=D..'/policy'..family..'.restore'
            atomic(path,iptables_payload(s,ps,w,family,true))
            local bin=family==4 and 'iptables-restore' or 'ip6tables-restore'
            assert(os.execute(command({bin,'--noflush'})..' < '..quote(path)..' >/dev/null 2>&1')==0,'Could not apply IPv'..family..' policies')
        end
    end
    -- These priority/mark ranges belong exclusively to this manager.
    for family=4,6,2 do
        local rules=capture({'ip','-'..family,'rule','show'})
        for row in rules:gmatch('[^\n]+') do
            local n=tonumber(row:match('^(%d+):'))
            local mark=row:match('fwmark%s+(0x%x+/0x%x+)')
            local tableid=tonumber(row:match('lookup%s+(%d+)'))
            if n and n>=100 and n<=227 and tableid==n+2101 and mark==string.format('0x%x/0xff0000',(n-99)*65536) then
                run({'ip','-'..family,'rule','del','pref',n,'fwmark',mark,'lookup',tableid})
            end
        end
    end
    for i,p in ipairs(ps) do
        if p.mode~='local-only' then
            route_table(s,p,w,2200+i)
            for _,family in ipairs({4,6}) do assert(run({'ip','-'..family,'rule','add','pref',99+i,'fwmark',string.format('0x%x/0x00ff0000',i*65536),'lookup',2200+i}),'Cannot install policy route') end
        end
    end
    for _,family in ipairs({4,6}) do
        -- Remove only our exact default rules, not unrelated priority-500 rules.
        for _,src in ipairs(s.lan_interfaces) do while run({'ip','-'..family,'rule','del','pref','500','iif',src,'lookup','2022'}) do end end
    end
    if wanted() and ready() and s.default_route=='sing-box' then
        route_table(s,{mode='sing-box'},w,2022)
        for _,src in ipairs(s.lan_interfaces) do for _,family in ipairs({4,6}) do
            assert(run({'ip','-'..family,'rule','add','pref','500','iif',src,'lookup','2022'}),'Cannot route LAN')
        end end
    end
    -- Separate NAT rule; explicit native VPNs retain their own GL configuration.
    if run({'nft','list','table','inet','fw4'}) then
        if not capture({'nft','list','chain','inet','fw4','srcnat'}):find('oifname "singtun0" masquerade',1,true) then assert(run({'nft','add','rule','inet','fw4','srcnat','oifname','singtun0','masquerade'}),'Cannot configure tunnel NAT') end
    else
        if not run({'iptables','-t','nat','-C','POSTROUTING','-o','singtun0','-j','MASQUERADE'}) then assert(run({'iptables','-t','nat','-A','POSTROUTING','-o','singtun0','-j','MASQUERADE'}),'Cannot configure NAT') end
    end
    return {ok=true}
end
function M.render(path)
    local c=assert(decode(read(path)), 'Invalid candidate JSON'); local s=settings(); check_settings(s)
    c.inbounds[1].auto_route=false
    c.inbounds[1].strict_route=false -- IPv6 is guarded by per-client policies, allowing native VPN IPv6.
    local w=wan(s)
    if w then c.route.auto_detect_interface=nil; c.route.default_interface=w.l3_device end
    local final=c.route.final
    local rules={{action='sniff'},{protocol='dns',action='hijack-dns'},{ip_is_private=true,outbound='direct'}}
    if #s.block_domains>0 then rules[#rules+1]={domain_suffix=s.block_domains,action='reject'} end
    if s.routing~='all' and #s.domains>0 then rules[#rules+1]={domain_suffix=s.domains,outbound=s.routing=='include' and final or 'direct'} end
    c.route.rules=rules
    if s.routing=='include' then c.route.final='direct' end
    local remote=c.dns.servers[1]
    if s.dns=='https' then
        local host,path=s.dns_address:match('^https://([^/]+)(/.*)$')
        remote.type='https'; remote.server=host; remote.path=path
        remote.domain_resolver='direct-dns'
    else remote.type='udp'; remote.server=s.dns_address end
    atomic(path,json.encode(c))
end
function M.status()
    local s=settings(); local version=decode(capture({'curl','--noproxy','*','-fsS','--max-time','2',API..'/version'}),{})
    local observed=trim(read(D..'/health')); local ts,state=observed:match('^(%d+)|([%w%-]+)$')
    if not wanted() then state='off'
    elseif not version.version then state='error'
    elseif not ts or os.time()-tonumber(ts)>45 then state='connecting' end
    return {ok=true,enabled=wanted(),running=version.version~=nil,state=state or 'connecting',
        killswitch=trim(read(D..'/ks.enabled'))=='1',settings=s,policies=policies(),
        selected=trim(read(D..'/selected')),core=version.version or '',version=trim(read(D..'/version')),
        ipv6='sing-box IPv6 blocked; native VPN IPv6 depends on its interface',
        warning=read(D..'/policy.error') or ''}
end
function M.devices()
    local out={}; local configured={}; for _,p in ipairs(policies()) do configured[p.mac or p.source_interface]=p end
    for row in (read('/tmp/dhcp.leases') or ''):gmatch('[^\n]+') do
        local _,mac,ip,name=row:match('^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)')
        if mac then out[#out+1]={mac=mac,ip=ip,name=name~='*' and name or mac,policy=configured[mac]}; configured[mac]=nil end
    end
    for _,p in pairs(configured) do out[#out+1]={mac=p.mac,name=p.name,policy=p} end
    return {ok=true,devices=out,interfaces=native()}
end
local function server_list()
    local result={}; local fav={}
    for t in (read(D..'/favorites') or ''):gmatch('[^\n]+') do fav[t]=true end
    for file in capture({'ls','-1',D..'/servers'}):gmatch('[^\n]+') do
        local t=file:match('^([%w_.%-]+)%.json$')
        if t then
            local v=decode(read(D..'/servers/'..file),{})
            result[#result+1]={tag=t,type=v.type,server=v.server,favorite=not not fav[t]}
        end
    end
    local selected=decode(capture({'curl','--noproxy','*','-fsS','--max-time','2',API..'/proxies/select'}),{})
    return {ok=true,servers=result,selected=selected.now or trim(read(D..'/selected'))}
end
local function export_backup()
    local files={}
    for _,name in ipairs({'settings.json','policies.json','selected','favorites','vpn.enabled','ks.enabled'}) do files[name]=read(D..'/'..name) end
    for _,dir in ipairs({'servers','subs'}) do
        for file in capture({'ls','-1',D..'/'..dir}):gmatch('[^\n]+') do
            if file:match('^[%w][%w_.%-]*$') then files[dir..'/'..file]=read(D..'/'..dir..'/'..file) end
        end
    end
    return {ok=true,schema=1,warning='Contains private VPN credentials and subscription URLs. Keep offline.',files=files}
end
local function locked(fn)
    local lock=D..'/.manager.lock'
    if not run({'mkdir',lock}) then
        local pid=trim(read(lock..'/pid'))
        if pid:match('^%d+$') and not run({'kill','-0',pid}) then
            os.remove(lock..'/pid'); run({'rmdir',lock})
        end
        assert(run({'mkdir',lock}), 'Another manager operation is running')
    end
    atomic(lock..'/pid',assert(read('/proc/self/stat')):match('^(%d+)'))
    local ok,result=pcall(fn); os.remove(lock..'/pid'); run({'rmdir',lock})
    if not ok then error(result) end
    return result
end
local function main(op,input)
    if op=='status' then return M.status()
    elseif op=='devices' then return M.devices()
    elseif op=='servers' then return server_list()
    elseif op=='backup' then return export_backup()
    elseif op=='diagnostics' then
        local st=M.status()
        return {ok=true,state=st.state,core=st.core,version=st.version,warning=st.warning,
            firewall=run({'nft','list','table','inet','fw4'}) and 'fw4' or 'fw3',
            rules4=capture({'ip','-4','rule','show'}),rules6=capture({'ip','-6','rule','show'}),
            policy_count=#policies(),ipv6=st.ipv6}
    elseif op=='validate-selection' then
        for _,o in ipairs(assert(decode(read(D..'/reality_full.json'))).outbounds) do
            if o.tag=='select' then for _,t in ipairs(o.outbounds) do if t==arg[2] then return {ok=true} end end end
        end
        error('Server or pool unavailable')
    elseif op=='settings' then return {ok=true,settings=settings()}
    elseif op=='policies' then return {ok=true,policies=policies()}
    elseif op=='render' then M.render(assert(arg[2])); return {ok=true}
    elseif op=='wan' then local w=wan(settings()); print(w and w.l3_device or ''); return nil
    elseif op=='guard-status' then
        local s=settings(); local ps=policies(); local ok=true
        local protected=trim(read(D..'/ks.enabled'))=='1'
        if run({'nft','list','table','inet','fw4'}) then
            local rules=capture({'nft','list','chain','inet','sb_policy','guard'})
            ok=rules:find('hook forward',1,true)~=nil
            for _,p in ipairs(ps) do
                if p.mac then ok=ok and rules:lower():find('ether saddr '..p.mac..' drop',1,true)~=nil
                else ok=ok and rules:find('iifname "'..p.source_interface..'" drop',1,true)~=nil end
            end
            if protected then for _,src in ipairs(s.lan_interfaces) do ok=ok and rules:find('iifname "'..src..'" drop',1,true)~=nil end end
            if wanted() and ready() then ok=ok and capture({'nft','list','chain','inet','fw4','forward'}):find('jump SB_ACCEPT',1,true)~=nil end
        else
            for _,bin in ipairs({'iptables','ip6tables'}) do
                ok=ok and run({bin,'-C','FORWARD','-j','SB_POLICY'})
                for _,p in ipairs(ps) do ok=ok and run(join({bin,'-C','SB_POLICY'},join(selector(p),{'-j','DROP'}))) end
                if protected then for _,src in ipairs(s.lan_interfaces) do ok=ok and run({bin,'-C','SB_POLICY','-i',src,'-j','DROP'}) end end
            end
        end
        return {ok=not not ok}
    end
    return locked(function()
        if op=='apply' then return M.apply()
        elseif op=='enabled' then
            assert(type(input.on)=='boolean','Expected boolean')
            local out=capture({'env','SB_SKIP_APPLY=1','sh',D..'/control.sh',input.on and 'on' or 'off'})
            M.apply()
            assert(out:match('^OK'),'Daemon did not become ready; see diagnostics')
            return {ok=true}
        elseif op=='killswitch' then
            assert(type(input.on)=='boolean','Expected boolean')
            local old=read(D..'/ks.enabled') or '0'
            atomic(D..'/ks.enabled',input.on and '1' or '0')
            local ok,err=pcall(M.apply)
            if not ok then atomic(D..'/ks.enabled',old); pcall(M.apply); error(err) end
            return {ok=true}
        elseif op=='select' then
            assert(tag(input.tag),'Invalid selection')
            assert(capture({'sh',D..'/select-server.sh',input.tag}):match('^OK'),'Could not select server')
            return {ok=true}
        elseif op=='import' then
            assert(type(input.text)=='string' and #input.text<=1048576,'Import too large')
            atomic(D..'/.import-input',input.text)
            local out=capture({'sh','-c','SB_SKIP_APPLY=1 sh '..quote(D..'/import-links.sh')..' < '..quote(D..'/.import-input')})
            os.remove(D..'/.import-input'); M.apply()
            return decode(out,{ok=false,msg='Import failed'})
        elseif op=='favorite' then
            assert(tag(input.tag) and read(D..'/servers/'..input.tag..'.json'),'Invalid server')
            local tags={}
            for t in (read(D..'/favorites') or ''):gmatch('[^\n]+') do if t~=input.tag then tags[#tags+1]=t end end
            if input.on then tags[#tags+1]=input.tag end
            atomic(D..'/favorites',table.concat(tags,'\n')..'\n')
            atomic(D..'/favorites.pending','1')
            return {ok=true,msg='Favorites saved. Apply to update the automatic pool.'}
        elseif op=='apply-favorites' then
            local out=capture({'env','SB_SKIP_APPLY=1','sh',D..'/rebuild.sh'})
            assert(out:match('^OK'),'Could not apply favorites')
            M.apply(); os.remove(D..'/favorites.pending'); return {ok=true}
        elseif op=='set-policy' or op=='delete-policy' then
            local s=settings(); local ps=policies(); local p=check_policy(input,s); local next={}
            for _,v in ipairs(ps) do if v.id~=p.id then next[#next+1]=v end end
            if op~='delete-policy' and p.mode~='inherit' then next[#next+1]=p end
            local ok,err=pcall(M.apply,s,next)
            if not ok then pcall(M.apply,s,ps); error(err) end
            atomic(D..'/policies.json',json.encode(next)); return {ok=true}
        elseif op=='set-settings' then
            local old=settings(); local s=input
            for k,v in pairs(defaults) do if s[k]==nil then s[k]=v end end
            check_settings(s); local ps=policies(); for _,p in ipairs(ps) do check_policy(p,s) end
            atomic(D..'/settings.json',json.encode(s))
            local out=capture({'env','SB_SKIP_APPLY=1','sh',D..'/rebuild.sh'})
            if not out:match('^OK') then
                atomic(D..'/settings.json',json.encode(old)); capture({'env','SB_SKIP_APPLY=1','sh',D..'/rebuild.sh'}); error('Settings rejected; previous settings restored')
            end
            local ok,result=pcall(M.apply,s,ps)
            if not ok then
                atomic(D..'/settings.json',json.encode(old)); capture({'env','SB_SKIP_APPLY=1','sh',D..'/rebuild.sh'}); pcall(M.apply,old,ps)
                error('Policy update failed; previous settings restored')
            end
            return result
        elseif op=='delete-subscription' then
            assert(tag(input.id),'Invalid subscription')
            local result=decode(capture({'env','SB_SKIP_APPLY=1','sh',D..'/sub-store.sh','del',input.id}),{ok=false}); M.apply(); return result
        elseif op=='delete-server' then
            assert(tag(input.tag),'Invalid server')
            local out=capture({'env','SB_SKIP_APPLY=1','sh',D..'/del-server.sh',input.tag})
            M.apply(); return {ok=out:match('^removed ')~=nil,msg=out}
        elseif op=='subscriptions' then return decode(capture({'sh',D..'/sub-store.sh','list'}),{ok=false})
        elseif op=='add-subscription' then
            assert(type(input.url)=='string' and #input.url<=4096 and input.url:match('^https?://'),'Invalid subscription URL')
            local result=decode(capture({'env','SB_SKIP_APPLY=1','sh',D..'/sub-store.sh','add',input.url,tostring(input.name or '')}),{ok=false}); M.apply(); return result
        elseif op=='refresh-subscriptions' then local result=decode(capture({'env','SB_SKIP_APPLY=1','sh',D..'/sub-store.sh','refresh','all'}),{ok=false}); M.apply(); return result
        else error('Unknown operation') end
    end)
end
local ok,result=pcall(function()
    local op=arg[1] or 'status'
    local writes={['set-policy']=true,['delete-policy']=true,['set-settings']=true,['add-subscription']=true,['delete-subscription']=true,['delete-server']=true,enabled=true,killswitch=true,select=true,import=true,favorite=true}
    local input=writes[op] and assert(decode(io.read('*a')),'Invalid JSON') or {}
    assert(type(input)=='table','Expected JSON object')
    return main(arg[1] or 'status',input)
end)
if not ok then
    local msg=tostring(result):gsub('^.-:%d+: ','')
    if arg[1]=='apply' then pcall(atomic,D..'/policy.error',msg) end
    io.write(json.encode({ok=false,msg=msg})..'\n'); os.exit(1)
end
if arg[1]=='apply' then os.remove(D..'/policy.error') end
if result~=nil then io.write(json.encode(result)..'\n') end
