"""Update checking with simulated DNS/TLS/raw-host failures and GL pipe limits."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
CURL='''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; url=args[-1]
with open(os.environ['SBDIR']+'/requests.jsonl','a') as f:f.write(json.dumps(args)+'\\n')
mode=os.getenv('UPDATE_FIXTURE','raw')
api='api.github.com' in url
proxy='--proxy' in args
body='2.0.0-beta.2'; code=200
if mode=='all-fail' or (mode=='api' and not api) or (mode=='proxy' and not proxy):
 body=''; code=0
elif mode=='invalid' and not api:body='<html>Access denied</html>'
elif mode=='all-invalid':body='2.0.0-beta.2\\n<script>untrusted</script>'
elif mode=='semver':body=' v3.2.1-rc.1+build.7 \\r\\n'
print(body+'\\n__SB_UPDATE_HTTP:%03d'%code)
'''

class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.d=Path(self.tmp.name)
        self.bin=self.d/'bin';self.bin.mkdir()
        self.env=dict(os.environ,SBDIR=str(self.d),PATH=str(self.bin)+':'+os.environ['PATH'])
        (self.bin/'curl').write_text(CURL);(self.bin/'curl').chmod(0o755)
        (self.d/'version').write_text('1.6.0\n')
        shutil.copy(ROOT/'check-update.lua',self.d/'check-update.lua')

    def tearDown(self):self.tmp.cleanup()

    def check(self,mode='raw'):
        p=subprocess.run(['lua',str(self.d/'check-update.lua')],env=dict(self.env,UPDATE_FIXTURE=mode),text=True,capture_output=True,check=True)
        return json.loads(p.stdout)

    def requests(self):return [json.loads(s) for s in (self.d/'requests.jsonl').read_text().splitlines()]

    def test_raw_response_and_installed_file(self):
        r=self.check();self.assertEqual('1.6.0',r['installed']);self.assertEqual('2.0.0-beta.2',r['latest']);self.assertTrue(r['update'])
        self.assertEqual(1,len(self.requests()));self.assertIn('-4',self.requests()[0])

    def test_unavailable_raw_host_falls_back_to_github_api(self):
        r=self.check('api');self.assertTrue(r['ok']);self.assertEqual('github-api-ipv4',r['source'])
        self.assertIn('Accept: application/vnd.github.raw+json',self.requests()[1])

    def test_html_is_not_accepted_as_a_version(self):
        self.assertEqual('github-api-ipv4',self.check('invalid')['source'])

    def test_proxy_used_only_when_vpn_is_enabled(self):
        (self.d/'vpn.enabled').write_text('1\n');r=self.check('proxy')
        self.assertTrue(r['ok']);self.assertEqual('vpn-proxy',r['source'])
        self.assertIn('socks5h://127.0.0.1:2080',self.requests()[-1])

    def test_vpn_off_does_not_use_local_proxy(self):
        (self.d/'vpn.enabled').write_text('0\n');r=self.check('proxy')
        self.assertFalse(r['ok']);self.assertEqual(2,len(self.requests()))

    def test_failure_has_diagnostics_and_never_reports_up_to_date(self):
        r=self.check('all-fail');self.assertFalse(r['ok']);self.assertFalse(r['update'])
        self.assertEqual('version_fetch_failed',r['error']);self.assertIn('DNS',r['msg'])
        self.assertEqual([0,0],[a['http_status'] for a in r['attempts']])

    def test_invalid_responses_do_not_become_update_targets(self):
        r=self.check('all-invalid');self.assertEqual('unknown',r['latest']);self.assertFalse(r['update'])

    def test_missing_installed_marker_keeps_available_version(self):
        (self.d/'version').unlink();r=self.check();self.assertEqual('unknown',r['installed']);self.assertTrue(r['update'])

    def test_matching_version_is_up_to_date(self):
        (self.d/'version').write_text('2.0.0-beta.2\r\n');self.assertFalse(self.check()['update'])

    def test_prerelease_and_build_metadata(self):
        self.assertEqual('3.2.1-rc.1+build.7',self.check('semver')['latest'])

    def test_native_rpc_works_without_pipeline_stdout_or_external_timeout(self):
        module=self.d/'module.lua'
        module.write_text((ROOT/'sdk4-tab/reality.oui.lua').read_text().replace('/etc/sing-box',str(self.d)))
        harness=self.d/'rpc.lua';harness.write_text('''ngx={pipe={spawn=function(args)
 assert(args[1]~="timeout", "External timeout unavailable")
 local cmd=args[#args]
 if cmd:find("|",1,true) then return {stdout_read_all=function() return "" end} end
 local p=io.popen(cmd)
 return {set_timeouts=function() end,stdout_read_all=function() local s=p:read("*a"); p:close(); return s end}
end}}
local m=dofile(arg[1]); local r=m.check_update({})
assert(r.installed=="1.6.0"); assert(r.latest=="2.0.0-beta.2"); assert(r.update)
''')
        subprocess.run(['lua',str(harness),str(module)],env=self.env,capture_output=True,check=True)

if __name__=='__main__':unittest.main()
