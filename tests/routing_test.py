import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ.get('ROUTING_SOURCE', Path(__file__).resolve().parents[1]))
MOCK = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['FW_STATE'])
s=json.loads(p.read_text()) if p.exists() else {}
f=Path(sys.argv[0]).name
c=s.setdefault(f, {'FORWARD': []})
a=sys.argv[1:]; op=a[0]; name=a[1]; rule=a[2:]
rc=0
if os.environ.get('FW_FAIL') == f + ':' + op:
    sys.exit(1)
if op == '-nL': rc=int(name not in c)
elif op == '-N':
    rc=int(name in c)
    if not rc: c[name]=[]
elif op == '-C': rc=int(rule not in c.get(name, []))
elif op == '-A': c[name].append(rule)
elif op == '-I': c[name].insert(0,rule)
elif op == '-F': c[name]=[]
elif op == '-X': del c[name]
elif op == '-D':
    rc=int(rule not in c.get(name, []))
    if not rc: c[name].remove(rule)
else: raise RuntimeError(a)
p.write_text(json.dumps(s))
with open(os.environ['FW_TRACE'], 'a') as t:
    t.write(json.dumps({'family':f,'args':a,'state':s})+'\\n')
sys.exit(rc)
'''


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.sb = self.base / 'sing-box'
        self.sb.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin',
                        SBDIR=str(self.sb), FW_STATE=str(self.base / 'fw.json'),
                        FW_TRACE=str(self.base / 'trace'))
        for name in ('iptables', 'ip6tables'):
            self.script(name, MOCK)
        self.script('nft', '#!/bin/sh\nexit 1\n')
        self.script('sleep', '#!/bin/sh\nexit 0\n')
        self.script('swapon', '#!/bin/sh\nexit 1\n')
        self.script('sing-box', '#!/usr/bin/python3\nimport json,sys\njson.load(open(sys.argv[-1]))\n')

    def script(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def ks(self, expression):
        return subprocess.run(['/bin/sh', '-c', '. "$1"; ' + expression,
                               'sh', str(ROOT / 'ks-lib.sh')],
                              env=self.env, capture_output=True, text=True)

    def state(self):
        return json.loads((self.base / 'fw.json').read_text())

    def rebuild(self, servers=True, check_only=True):
        srv = self.sb / 'servers'
        srv.mkdir()
        if servers:
            (srv / 'test.json').write_text(json.dumps({
                'type': 'vless', 'tag': 'test', 'server': 'example.com',
                'server_port': 443, 'uuid': '00000000-0000-0000-0000-000000000001'}))
            (self.sb / 'favorites').write_text('test\n')
        self.env['REBUILD_CHECK_ONLY'] = '1' if check_only else '0'
        # Even baseline runs may never invoke a service on the test host.
        service = self.base / 'service'
        service.write_text('#!/bin/sh\necho restart >> "$SBDIR/service-calls"\n')
        service.chmod(0o755)
        source = (ROOT / 'rebuild.sh').read_text().replace('/etc/init.d/sing-box', str(service))
        safe = self.base / 'rebuild.sh'
        safe.write_text(source)
        result = subprocess.run(['sh', str(safe)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.sb / 'service-calls').exists(), 'validation started the VPN')
        return json.loads((self.sb / 'reality_full.json').read_text())

    def test_dns_uses_selected_vpn_and_bootstrap_direct(self):
        cfg = self.rebuild()
        dns = {s['tag']: s for s in cfg['dns']['servers']}
        self.assertEqual(dns['remote'].get('detour'), 'select')
        self.assertEqual(dns['direct-dns'].get('detour'), 'direct')
        self.assertEqual(cfg['route']['default_domain_resolver'], 'direct-dns')
        self.assertEqual(next(s for s in cfg['outbounds'] if s['tag'] == 'auto-fav')['outbounds'], ['test'])

    def test_disabled_vpn_rebuild_does_not_start_service(self):
        (self.sb / 'vpn.enabled').write_text('0\n')
        self.rebuild(check_only=False)

    def test_empty_config_dns_direct(self):
        cfg = self.rebuild(False)
        self.assertEqual(cfg['dns']['servers'][0].get('detour'), 'direct')
        self.assertEqual(cfg['route']['final'], 'direct')

    def test_both_families_and_tunnels(self):
        result = self.ks('ks_apply && ks_present')
        self.assertEqual(result.returncode, 0, result.stderr)
        for family in ('iptables', 'ip6tables'):
            state = self.state()[family]
            self.assertIn(['-i', 'br-lan', '-j', 'SB_KS'], state['FORWARD'])
            self.assertEqual(state['SB_KS'][-1], ['-j', 'DROP'])
            for iface in ('br-lan', 'singtun0', 'tun+', 'wg+', 'awg+'):
                self.assertIn(['-o', iface, '-j', 'RETURN'], state['SB_KS'])

    def test_reapply_never_empties_attached_chain(self):
        self.assertEqual(self.ks('ks_apply').returncode, 0)
        (self.base / 'trace').write_text('')
        self.assertEqual(self.ks('ks_apply').returncode, 0)
        for line in (self.base / 'trace').read_text().splitlines():
            record = json.loads(line)
            for state in record['state'].values():
                if ['-i', 'br-lan', '-j', 'SB_KS'] in state['FORWARD']:
                    self.assertIn(['-j', 'DROP'], state['SB_KS'], record['args'])

    def test_rule_failure_is_reported_and_chain_not_attached(self):
        self.env['FW_FAIL'] = 'iptables:-A'
        self.assertNotEqual(self.ks('ks_apply').returncode, 0)
        self.assertEqual(self.state()['iptables']['FORWARD'], [])

    def test_ipv6_failure_never_reports_protected(self):
        self.env['FW_FAIL'] = 'ip6tables:-A'
        self.assertNotEqual(self.ks('ks_apply').returncode, 0)
        self.assertNotEqual(self.ks('ks_present').returncode, 0)

    def test_missing_ipv6_tool_never_reports_protected(self):
        (self.bin / 'ip6tables').unlink()
        self.env['PATH'] = str(self.bin)
        result = self.ks('ks_apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires ip6tables', result.stderr)
        self.assertNotEqual(self.ks('ks_present').returncode, 0)

    def test_fw4_uses_inet_table_for_both_families(self):
        self.script('nft', """#!/bin/sh
if [ "$*" = 'list table inet fw4' ]; then exit 0; fi
if [ "$*" = 'list table inet sb_ks' ]; then test -f "$SBDIR/nft-rules"; exit $?; fi
if [ "$*" = '-f -' ]; then cat > "$SBDIR/nft-rules"; exit $?; fi
if [ "$*" = 'delete table inet sb_ks' ]; then rm "$SBDIR/nft-rules"; exit $?; fi
exit 1
""")
        self.assertEqual(self.ks('ks_apply && ks_present').returncode, 0)
        rules = (self.sb / 'nft-rules').read_text()
        self.assertIn('table inet sb_ks', rules)
        self.assertIn('iifname "br-lan" drop', rules)
        self.assertIn('oifname "wg*" accept', rules)
        self.assertFalse((self.base / 'fw.json').exists())
        self.assertEqual(self.ks('ks_remove').returncode, 0)
        self.assertNotEqual(self.ks('ks_present').returncode, 0)

    def test_disarm_removes_both_families(self):
        self.assertEqual(self.ks('ks_apply; ks_remove').returncode, 0)
        for state in self.state().values():
            self.assertEqual(state, {'FORWARD': []})

    def test_failed_removal_reports_failure_and_keeps_guard(self):
        self.assertEqual(self.ks('ks_apply').returncode, 0)
        self.env['FW_FAIL'] = 'iptables:-D'
        self.assertNotEqual(self.ks('ks_remove').returncode, 0)
        self.assertIn(['-j', 'DROP'], self.state()['iptables']['SB_KS'])

    def test_guard_independent_of_vpn_desired(self):
        (self.sb / 'ks.enabled').write_text('1\n')
        (self.sb / 'vpn.enabled').write_text('0\n')
        self.assertEqual(self.ks('ks_enforce && ks_present').returncode, 0)
        (self.sb / 'ks.enabled').write_text('0\n')
        self.assertEqual(self.ks('ks_enforce').returncode, 0)
        self.assertNotEqual(self.ks('ks_present').returncode, 0)


if __name__ == '__main__':
    unittest.main()
