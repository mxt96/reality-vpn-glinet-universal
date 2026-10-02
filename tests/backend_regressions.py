import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.sb = self.base / 'sb'
        (self.sb / 'servers').mkdir(parents=True)
        (self.sb / 'subs').mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, SBDIR=str(self.sb), PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.script(self.bin / 'curl', 'exit 1')
        self.script(self.sb / 'rebuild.sh', 'echo OK')
        self.script(self.sb / 'import-links.sh', 'echo \'{"ok":false,"added":0,"msg":"network failure"}\'')
        (self.sb / 'subs/home.url').write_text('home\nhttps://example.test/sub\n')
        (self.sb / 'subs/home.tags').write_text('srv-home\n')
        (self.sb / 'subs/home.upd').write_text('123\n')
        (self.sb / 'servers/srv-home.json').write_text('{"tag":"srv-home","server":"old"}')

    def tearDown(self):
        self.tmp.cleanup()

    def script(self, path, text):
        path.write_text('#!/bin/sh\n' + text + '\n')
        path.chmod(0o755)

    def sub(self, *args):
        p = subprocess.run(['sh', str(ROOT / 'sub-store.sh'), *args], env=self.env, capture_output=True, text=True, check=True)
        return json.loads(p.stdout)

    def test_refresh_failure_preserves_subscription(self):
        result = self.sub('refresh', 'home')
        self.assertFalse(result['ok'])
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())
        self.assertEqual('srv-home\n', (self.sb / 'subs/home.tags').read_text())
        self.assertEqual('123\n', (self.sb / 'subs/home.upd').read_text())

    def test_repeated_add_failure_preserves_subscription(self):
        self.assertFalse(self.sub('add', 'https://example.test/sub', 'home')['ok'])
        self.assertTrue((self.sb / 'subs/home.url').exists())
        self.assertTrue((self.sb / 'servers/srv-home.json').exists())

    def use_real_import(self):
        (self.sb / 'import-links.sh').write_text((ROOT / 'import-links.sh').read_text())
        for name in ('parse-link.sh',):
            self.script(self.sb / name, (ROOT / name).read_text())
        # Stage resolves the parser next to the installed import script.
        self.script(self.bin / 'curl', "echo 'trojan://secret@example.test:443#home'")

    def test_successful_refresh_replaces_only_owned_servers(self):
        self.use_real_import()
        (self.sb / 'servers/manual.json').write_text('{"tag":"manual","server":"manual"}')
        result = self.sub('refresh', 'home')
        self.assertTrue(result['ok'])
        self.assertEqual(1, result['added'])
        self.assertEqual('srv-home\n', (self.sb / 'subs/home.tags').read_text())
        self.assertIn('example.test', (self.sb / 'servers/srv-home.json').read_text())
        self.assertIn('manual', (self.sb / 'servers/manual.json').read_text())
        self.assertFalse(list(self.sb.glob('.sub-stage.*')))

    def test_rebuild_rejection_rolls_back_live_servers(self):
        self.use_real_import()
        self.script(self.sb / 'rebuild.sh', 'if [ "$REBUILD_CHECK_ONLY" = 1 ]; then echo OK; else echo CHECK_FAIL; fi')
        result = self.sub('refresh', 'home')
        self.assertFalse(result['ok'])
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())
        self.assertEqual('123\n', (self.sb / 'subs/home.upd').read_text())
        self.assertFalse(list(self.sb.glob('.sub-stage.*')))

    def test_stage_validation_rejection_preserves_live_servers(self):
        self.use_real_import()
        self.script(self.sb / 'rebuild.sh', 'echo CHECK_FAIL')
        self.assertFalse(self.sub('refresh', 'home')['ok'])
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())

    def test_failed_snapshot_copy_preserves_all_servers(self):
        self.use_real_import()
        (self.sb / 'servers/manual.json').write_text('manual')
        self.script(self.bin / 'cp', 'case "$*" in *manual.json*) exit 1;; esac; exec /bin/cp "$@"')
        self.assertFalse(self.sub('refresh', 'home')['ok'])
        self.assertEqual('manual', (self.sb / 'servers/manual.json').read_text())
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())

    def test_server_lock_rejects_parallel_import_and_refresh(self):
        self.use_real_import()
        (self.sb / '.servers.lock').mkdir()
        self.assertFalse(self.sub('refresh', 'home')['ok'])
        result = subprocess.run(['sh', str(ROOT / 'import-links.sh')], input='trojan://secret@example.test:443#home', env=self.env, text=True, capture_output=True, check=True)
        self.assertFalse(json.loads(result.stdout)['ok'])
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())

    def run_lua(self, code):
        module = self.base / 'module.lua'
        module.write_text((ROOT / 'sdk4-tab/reality.oui.lua').read_text().replace('/etc/sing-box', str(self.sb)).replace('/tmp/reality-', str(self.base / 'reality-')))
        harness = self.base / 'test.lua'
        harness.write_text('''package.preload.cjson = function() return {} end
ngx = {time = function() return 1 end, pipe = {spawn = function(args)
 local p = io.popen(args[#args]); return {stdout_read_all = function() local s = p:read("*a"); p:close(); return s end, set_timeouts = function() end}
end}}
local m = dofile(arg[1])
''' + code)
        subprocess.run(['lua', str(harness), str(module)], env=self.env, check=True, capture_output=True)

    def test_favorites_save_without_rebuild_then_apply_once(self):
        log = self.base / 'rebuild-log'
        self.script(self.sb / 'rebuild.sh', f'echo rebuild >> "{log}"; echo OK')
        self.run_lua('assert(m.set_fav({tag="srv-home", on=true}).ok)')
        self.assertFalse(log.exists())
        self.assertTrue((self.sb / 'favorites.pending').exists())
        self.run_lua('assert(m.apply_favorites().ok)')
        self.assertEqual('rebuild\n', log.read_text())
        self.assertFalse((self.sb / 'favorites.pending').exists())
        self.assertFalse((self.sb / '.servers.lock').exists())

    def test_favorites_failed_apply_keeps_pending(self):
        (self.sb / 'favorites.pending').touch()
        self.script(self.sb / 'rebuild.sh', 'echo CHECK_FAIL')
        self.run_lua('assert(not m.apply_favorites().ok)')
        self.assertTrue((self.sb / 'favorites.pending').exists())
        self.assertFalse((self.sb / '.servers.lock').exists())

    def test_selector_rejects_empty_favorites_and_api_failure(self):
        self.run_lua('assert(not m.set_proto({proto="auto-fav"}).ok)')
        self.run_lua('assert(not m.set_proto({proto="srv-home"}).ok)')

    def test_password_change_failure(self):
        self.script(self.bin / 'chpasswd', 'cat >/dev/null; exit 1')
        self.script(self.sb / 'ks-lib.sh', ':')
        panel = (ROOT / 'panel/api').read_text().replace('/etc/sing-box', str(self.sb)).replace('/tmp/lk-', str(self.base / 'lk-'))
        path = self.base / 'api'
        path.write_text(panel)
        sessions = self.base / 'lk-sess'
        sessions.mkdir()
        (sessions / 'abcdefgh').write_text('9999999999')
        p = subprocess.run(['sh', str(path)], input='password', env=dict(self.env, HTTP_COOKIE='sid=abcdefgh', QUERY_STRING='action=setpass', CONTENT_LENGTH='8'), text=True, capture_output=True, check=True)
        self.assertFalse(json.loads(p.stdout.split('\n\n')[-1])['ok'])

    def test_lua_duplicate_rejection_preserves_original(self):
        self.script(self.sb / 'parse-link.sh', 'echo "{\\"tag\\":\\"$2\\"}"')
        self.script(self.sb / 'rebuild.sh', 'echo CHECK_FAIL')
        lua = (ROOT / 'sdk4-tab/reality.oui.lua').read_text().replace('/etc/sing-box', str(self.sb)).replace('/tmp/reality-', str(self.base / 'reality-'))
        module = self.base / 'module.lua'
        module.write_text(lua)
        harness = self.base / 'test.lua'
        harness.write_text('''package.preload.cjson = function() return {} end
ngx = {time = function() return 1 end, pipe = {spawn = function(args)
 local p = io.popen(args[#args]); return {stdout_read_all = function() local s = p:read("*a"); p:close(); return s end, set_timeouts = function() end}
end}}
local m = dofile(arg[1])
local result = m.add_server({name="home", link="test"})
assert(result.ok == false)
''')
        subprocess.run(['lua', str(harness), str(module)], env=self.env, check=True, capture_output=True)
        self.assertIn('old', (self.sb / 'servers/srv-home.json').read_text())


if __name__ == '__main__':
    unittest.main()
