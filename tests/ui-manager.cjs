const fs=require('node:fs'), assert=require('node:assert/strict'), {chromium}=require('playwright');
const html=fs.readFileSync(require('node:path').join(__dirname,'../panel/manager.html'),'utf8');
(async()=>{const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined,args:['--no-sandbox']});try{
const page=await browser.newPage({viewport:{width:390,height:844}}), errors=[], calls=[];
page.on('pageerror',e=>errors.push(e.message));
const settings={default_route:'sing-box',lan_interfaces:['br-lan'],wan:'wan',routing:'all',domains:[],block_domains:[],dns:'udp',dns_address:'8.8.8.8',subscription_hours:6};
let policy;
await page.route('http://router.test/**',async route=>{const req=route.request(),url=new URL(req.url());if(url.pathname==='/'){return route.fulfill({contentType:'text/html',body:html})}
await new Promise(resolve=>setTimeout(resolve,50));
const op=url.searchParams.get('op'), data=req.postData()?JSON.parse(req.postData()):undefined;calls.push({op,data,method:req.method()});
let body={ok:true};if(op==='status')body={...body,enabled:true,state:'connected',settings,killswitch:false,policies:policy?[policy]:[],version:'2.0.0',core:'1.14.4',ipv6:'blocked'};
if(op==='servers')body={...body,selected:'auto',servers:[{tag:'server1',type:'vless',favorite:false}]};
if(op==='devices')body={...body,devices:[{mac:'52:54:00:11:00:03',name:'LAN camera <script>alert(1)</script>',ip:'192.168.8.2',policy}],interfaces:[{l3_device:'wgclient'}]};
if(op==='set-policy')policy=data;
if(op==='set-settings')Object.assign(settings,data);
return route.fulfill({contentType:'application/json',body:JSON.stringify(body)})});
await page.goto('http://router.test/');await page.getByText('Connection verified',{exact:true}).waitFor();
assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'mobile overflow');
await page.getByRole('button',{name:'Devices',exact:true}).click();await page.getByText('Device access rules',{exact:true}).waitFor();
await page.getByLabel('Internet access',{exact:true}).first().selectOption('local-only');await page.getByRole('button',{name:'Apply rule',exact:true}).first().click();
await page.getByText('Saved',{exact:true}).waitFor();assert.equal(policy.mode,'local-only');assert.equal(policy.mac,'52:54:00:11:00:03');assert.equal(calls.find(x=>x.op==='set-policy').method,'POST');
assert.match(await page.locator('body').innerText(),/<script>alert\(1\)<\/script>/,'device name must remain text');
await page.getByRole('button',{name:'Routing',exact:true}).click();await page.getByLabel('Domains profile',{exact:true}).selectOption('include');await page.getByLabel('Domains, one per line',{exact:true}).fill('example.com\nexample.net');await Promise.all([page.waitForResponse(r=>r.url().includes('op=set-settings')),page.getByRole('button',{name:'Save and reconnect',exact:true}).click()]);
assert.deepEqual(settings.domains,['example.com','example.net']);assert.equal(settings.routing,'include');
await page.getByRole('button',{name:'Русский',exact:true}).click();await page.getByRole('button',{name:'Устройства',exact:true}).waitFor();
assert.deepEqual(errors,[]);console.log('PASS: shared manager mobile layout, local-only policy, POST mutation, safe device names, domain routing and Russian UI');
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)});
