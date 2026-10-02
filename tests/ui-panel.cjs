const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const vue = fs.readFileSync(require.resolve(process.env.VUE_MODULE || 'vue/dist/vue.js'), 'utf8');
const panel = fs.readFileSync(path.join(__dirname, '../sdk4-tab/gl-sdk4-ui-reality.common.js'), 'utf8');
(async () => {
  const browser = await chromium.launch({args: ['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport: {width: 1280, height: 1100}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('http://router.test/', route => route.fulfill({contentType: 'text/html', body: '<html></html>'}));
    await page.goto('http://router.test/');
    await page.setContent('<html lang="en"><head><style>body{font:14px/1.5 Arial;background:#f5f6f8;color:#262c38;margin:0}.shell{max-width:900px;margin:25px auto;padding:0 15px}.card{background:white;border:1px solid #e7e9ef;border-radius:9px;margin-bottom:16px}button,input,textarea,select{font:inherit}button{cursor:pointer}.gl-button{padding:7px 12px;border:1px solid #dce0e8;border-radius:5px;background:white;color:#3c5bd6}button:disabled{opacity:.6;cursor:default}input,textarea{box-sizing:border-box;width:100%;padding:9px;border:1px solid #dce0e8;border-radius:5px}p{overflow-wrap:anywhere}</style></head><body><div class="shell"><div id="app"></div></div></body></html>');
    await page.addScriptTag({content: vue});
    await page.evaluate(() => {
      window.calls = [];
      window.mock = {
        get_status: {running: true, killswitch: true, killswitch_active: true, mode: 'auto', active: 'srv-Frankfurt', egress: '203.0.113.42', country: 'Germany', ping: '38', favorites_pending: false},
        list_servers: {servers: [
          {tag: 'srv-Frankfurt', type: 'vless', fam: 'reality', fav: true},
          {tag: 'srv-Amsterdam', type: 'hysteria2', fav: true},
          {tag: 'srv-Helsinki', type: 'vless', fam: 'reality', fav: false}
        ]},
        list_subs: {subs: [{id: 'demo', name: 'My subscription', count: 3}]},
        ping_servers: {pings: {'srv-Frankfurt': 38, 'srv-Amsterdam': 45, 'srv-Helsinki': 57}},
        check_update: {installed: '1.5.9', latest: '1.5.9', update: false}
      };
      window.fetch = async (_, request) => {
        const [, , method, args] = JSON.parse(request.body).params;
        calls.push({method, args});
        if (method === 'set_fav') {
          mock.list_servers.servers.find(server => server.tag === args.tag).fav = !!args.on;
          mock.get_status.favorites_pending = true;
        }
        if (method === 'apply_favorites') mock.get_status.favorites_pending = false;
        const response = mock[method] || {ok: true};
        return {json: async () => ({result: JSON.parse(JSON.stringify(response))})};
      };
      Vue.component('gl-card', {render(h) {return h('section', {class: 'card'}, this.$slots.default);}});
      Vue.component('gl-button', {inheritAttrs: false, render(h) {return h('button', {class: 'gl-button', attrs: {disabled: this.$attrs.disabled || this.$attrs.loading}, on: {click: () => this.$emit('click')}}, this.$slots.default);}});
      Vue.component('gl-switch', {render(h) {return h('button', {attrs: {role: 'switch', 'aria-checked': this.$attrs.value, disabled: this.$attrs.disabled}, on: {click: () => this.$emit('change', !this.$attrs.value)}}, this.$attrs.value ? 'On' : 'Off');}});
      Vue.component('el-input', {inheritAttrs: false, render(h) {return h(this.$attrs.type === 'textarea' ? 'textarea' : 'input', {attrs: this.$attrs, domProps: {value: this.$attrs.value}, on: {input: e => this.$emit('input', e.target.value)}});}});
    });
    await page.addScriptTag({content: 'window.component = ' + panel + '; window.vm = new Vue(window.component).$mount("#app");'});
    await page.waitForFunction(() => vm.servers.length === 3 && vm.loaded);
    assert.match(await page.locator('body').innerText(), /Connection not verified/);
    assert.doesNotMatch(await page.locator('body').innerText(), /Online|Tunnel active|[А-Яа-яЁё]/);
    if (process.env.UI_SCREENSHOTS) {
      fs.mkdirSync(process.env.UI_SCREENSHOTS, {recursive: true});
      await page.screenshot({path: path.join(process.env.UI_SCREENSHOTS, 'desktop.png'), fullPage: true});
    }
    await page.setViewportSize({width: 390, height: 844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, 'mobile overflow');
    if (process.env.UI_SCREENSHOTS) await page.screenshot({path: path.join(process.env.UI_SCREENSHOTS, 'mobile.png'), fullPage: true});
    await page.evaluate(() => {mock.get_status.mode = 'auto-fav'; vm.autoPoolLoaded = false; return vm.refresh();});
    assert.equal(await page.evaluate(() => vm.autoPool), 'fav');
    await page.evaluate(() => {vm.autoPool = 'all'; return vm.refresh();});
    assert.equal(await page.evaluate(() => vm.autoPool), 'all', 'polling must preserve the chosen pool');
    await page.evaluate(() => {mock.get_status.mode = 'auto'; return vm.refresh();});
    await page.getByRole('button', {name: 'Remove favorite: Frankfurt', exact: true}).click();
    await page.waitForFunction(() => !vm.busy && vm.favoritesPending);
    assert.deepEqual(await page.evaluate(() => calls.filter(c => ['set_proto', 'set_enabled', 'apply_favorites'].includes(c.method))), [], 'favorite edit must not reconnect');
    await page.getByRole('button', {name: 'Apply and reconnect', exact: true}).click();
    await page.waitForFunction(() => !vm.busy);
    assert.deepEqual(await page.evaluate(() => calls.filter(c => ['set_proto', 'apply_favorites'].includes(c.method)).map(c => c.method)), ['apply_favorites', 'set_proto']);
    await page.locator('summary').filter({hasText: 'List filters'}).click();
    await page.evaluate(() => {calls.length = 0; vm.ccSel = {NL: 1};});
    await page.waitForFunction(() => document.body.innerText.includes('showing 1 of 3'));
    assert.equal(await page.evaluate(() => calls.filter(c => ['set_proto', 'apply_favorites', 'set_enabled'].includes(c.method)).length), 0, 'filter must not reconnect');
    await page.evaluate(async () => {
      vm.ccSel = {DE: 1, NL: 1, FI: 1};
      mock.list_servers.servers.push({tag: 'srv-London', type: 'vless', fav: false});
      await vm.loadServers();
    });
    await page.waitForFunction(() => document.body.innerText.includes('showing 4 of 4'));
    await page.evaluate(() => {vm.servers.forEach(server => {server.fav = false;}); vm.autoPool = 'fav'; calls.length = 0; vm.goAuto();});
    assert.equal(await page.evaluate(() => calls.length), 0, 'empty favorites must not fall back to all');
    await page.getByRole('button', {name: 'Delete', exact: true}).click();
    assert.equal(await page.evaluate(() => calls.filter(c => c.method === 'del_sub').length), 0, 'deletion needs confirmation');
    await page.getByRole('button', {name: 'Cancel', exact: true}).click();
    await page.evaluate(() => {mock.set_proto = {ok: false, msg: 'Selection failed'}; vm.setProto('srv-London');});
    await page.waitForFunction(() => vm.actionMsg === 'Selection failed' && !vm.busy);
    await page.evaluate(() => {mock.get_status.running = false; mock.get_status.killswitch = true; return vm.refresh();});
    assert.match(await page.locator('body').innerText(), /Direct internet blocked/);
    assert.doesNotMatch(await page.locator('body').innerText(), /Internet blocking is off/);
    await page.evaluate(() => {mock.get_status.killswitch_active = false; return vm.refresh();});
    assert.match(await page.locator('body').innerText(), /Internet blocking is not active/);
    assert.doesNotMatch(await page.locator('body').innerText(), /Direct internet blocked/);
    assert.deepEqual(errors, []);
    console.log('PASS: English UI; responsive layout; honest status; non-disruptive favorites; explicit apply; list-only filters; new-country visibility; empty-pool rejection; delete cancellation; RPC errors.');
  } finally {
    await browser.close();
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
