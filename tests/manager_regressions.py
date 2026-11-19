"""Behavioral tests of the shared Lua backend using isolated command adapters.
Packet forwarding is separately tested in QEMU; these adapters never touch host routes.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.sb = self.d / 'sb'
        self.sb.mkdir()
        (self.sb/'servers').mkdir()
        self.bin = self.d/'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, SBDIR=str(self.sb), PATH=str(self.bin)+':'+os.environ['PATH'])
        self.script('nft', 'exit 1')
        self.script('ip', '''echo "$*" >> "$SBDIR/ip.log"
case "$*" in
 *"rule del"*) exit 1;;
 *"rule show"*) echo '100: from 192.0.2.2 lookup 123';;
 "link show singtun0") [ ! -f "$SBDIR/down" ];;
 "link show "*) exit 1;;
 *"route show dev br-lan scope link"*) echo '192.168.8.0/24 proto kernel scope link';;
esac''')
        self.script('ubus', "echo '{\"interface\":[{\"interface\":\"wan\",\"up\":true,\"l3_device\":\"eth1\",\"route\":[{\"mask\":0,\"nexthop\":\"10.0.2.2\"}]}]}'")
        self.script('curl', '''case "$*" in *"/version"*) [ ! -f "$SBDIR/down" ] && echo '{"version":"1.14.4"}';; *"/proxies/select"*) echo '{"now":"auto"}';; *) printf 204;; esac''')
        self.script('uci', 'exit 0')
        for name in ['iptables', 'ip6tables']:
            self.script(name, 'case "$*" in *"-C "*) exit 1;; esac')
        for name in ['iptables-restore', 'ip6tables-restore']:
            self.script(name, f'cat > "$SBDIR/{name}.rules"')
        (self.sb/'vpn.enabled').write_text('1')
        (self.sb/'ks.enabled').write_text('0')

    def script(self, name, content):
        path=self.bin/name
        path.write_text('#!/bin/sh\n'+content+'\n')
        path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def manager(self, op, data=None, success=True, *args):
        result=subprocess.run(['lua', str(ROOT/'manager.lua'), op, *args],input=json.dumps(data or {}),env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout+result.stderr)
        return json.loads(result.stdout)

    def policy(self, mode='local-only', **extra):
        return dict(kind='device', mac='52:54:00:11:00:03', source_interface='br-lan', mode=mode, **extra)

    def test_local_only_blocks_both_families_preserves_local(self):
        self.manager('set-policy', self.policy())
        for fw in ['iptables-restore','ip6tables-restore']:
            rules=(self.sb/(fw+'.rules')).read_text()
            self.assertIn('--mac-source 52:54:00:11:00:03 -o br-lan -j ACCEPT',rules)
            self.assertIn('--mac-source 52:54:00:11:00:03 -j DROP',rules)
            self.assertNotIn('--mac-source 52:54:00:11:00:03 -o eth1',rules)
        self.assertEqual('local-only',json.loads((self.sb/'policies.json').read_text())[0]['mode'])

    def test_missing_native_tunnel_fails_closed(self):
        self.manager('set-policy',self.policy('interface',interface='wgclient'))
        routes=(self.sb/'ip.log').read_text()
        self.assertIn('unreachable default metric 32760 table 2201',routes)
        self.assertNotIn('default dev wgclient',routes)
        self.assertNotIn('default via 10.0.2.2 dev eth1 metric 10 table 2201',routes)

    def test_device_rule_precedes_network_rule_without_mark_overwrite(self):
        self.manager('set-policy',dict(kind='network',source_interface='br-lan',mode='direct'))
        self.manager('set-policy',self.policy('sing-box'))
        rules=(self.sb/'iptables-restore.rules').read_text()
        self.assertLess(rules.index('--mac-source'),rules.index('-A SB_POLICY -i br-lan -o br-lan'))
        self.assertIn('--mac-source 52:54:00:11:00:03 -j RETURN',rules)

    def test_foreign_priority_rule_is_preserved(self):
        self.manager('apply')
        self.assertNotIn('rule del pref 100', (self.sb/'ip.log').read_text())

    def test_policy_command_injection_rejected_without_mutation(self):
        for extra in [dict(mac="aa:bb:cc:dd:ee:ff;echo bad"),dict(source_interface='br-lan;echo bad'),dict(mode='interface',interface='eth1')]:
            p=self.policy();p.update(extra)
            self.assertFalse(self.manager('set-policy',p,False)['ok'])
        self.assertFalse((self.sb/'policies.json').exists())
        self.assertFalse((self.sb/'iptables-restore.rules').exists())

    def test_default_vpn_ipv6_is_unreachable(self):
        self.manager('apply')
        routes=(self.sb/'ip.log').read_text()
        self.assertIn('-6 route add unreachable default',routes)
        self.assertNotIn('-6 route add default dev singtun0',routes)
        self.assertIn('-6 rule add pref 500 iif br-lan lookup 2022',routes)

    def test_off_keeps_device_restrictions(self):
        (self.sb/'vpn.enabled').write_text('0')
        self.manager('set-policy',self.policy())
        self.assertIn('--mac-source 52:54:00:11:00:03 -j DROP',(self.sb/'ip6tables-restore.rules').read_text())
        self.assertNotIn('rule add pref 500',(self.sb/'ip.log').read_text())

    def test_core_liveness_does_not_claim_connected(self):
        self.assertEqual('connecting',self.manager('status')['state'])
        (self.sb/'down').touch()
        self.assertEqual('error',self.manager('status')['state'])

    def test_dead_manager_lock_is_reclaimed(self):
        (self.sb/'.manager.lock').mkdir()
        (self.sb/'.manager.lock/pid').write_text('99999999')
        self.manager('apply')
        self.assertFalse((self.sb/'.manager.lock').exists())

    def test_failed_firewall_apply_does_not_commit_policy(self):
        self.script('ip6tables-restore','cat >/dev/null; exit 1')
        self.assertFalse(self.manager('set-policy',self.policy(),False)['ok'])
        self.assertFalse((self.sb/'policies.json').exists())

    def test_invalid_domain_settings_preserve_live_file(self):
        original='{"routing":"all"}'
        (self.sb/'settings.json').write_text(original)
        self.manager('set-settings',dict(domains=['bad;exec']),False)
        self.assertEqual(original,(self.sb/'settings.json').read_text())

    def test_backup_contains_credentials_but_diagnostics_do_not(self):
        (self.sb/'servers/private.json').write_text('{"password":"SECRET_PASSWORD"}')
        self.assertIn('SECRET_PASSWORD',json.dumps(self.manager('backup')))
        self.assertNotIn('SECRET_PASSWORD',json.dumps(self.manager('diagnostics')))

    def test_selected_server_survives_rebuild_and_invalid_pool_falls_back(self):
        for name in ['runtime-lib.sh','manager.lua']:
            shutil.copy(ROOT/name,self.sb/name)
        self.script('sing-box','exit 0')
        (self.sb/'servers/test.json').write_text('{"type":"vless","tag":"test","server":"example.test","server_port":443,"uuid":"test"}')
        (self.sb/'selected').write_text('test')
        env=dict(self.env,REBUILD_CHECK_ONLY='1')
        subprocess.run(['sh',str(ROOT/'rebuild.sh')],env=env,check=True,capture_output=True)
        cfg=json.loads((self.sb/'reality_full.json').read_text())
        self.assertFalse(cfg['inbounds'][0]['auto_route'])
        self.assertEqual('test',next(x for x in cfg['outbounds'] if x['tag']=='select')['default'])
        (self.sb/'selected').write_text('auto-hy2')
        subprocess.run(['sh',str(ROOT/'rebuild.sh')],env=env,check=True,capture_output=True)
        cfg=json.loads((self.sb/'reality_full.json').read_text())
        self.assertEqual('auto',next(x for x in cfg['outbounds'] if x['tag']=='select')['default'])

    def test_failed_runtime_restores_config_and_reports_error(self):
        for name in ['runtime-lib.sh']:shutil.copy(ROOT/name,self.sb/name)
        self.script('sing-box','exit 0')
        self.script('service','exit 0')
        (self.sb/'down').touch()
        (self.sb/'reality_full.json').write_text('OLD_CONFIG')
        (self.sb/'servers/test.json').write_text('{"type":"vless","tag":"test"}')
        env=dict(self.env,SB_SERVICE=str(self.bin/'service'),SB_START_TIMEOUT='0')
        result=subprocess.run(['sh',str(ROOT/'rebuild.sh')],env=env,text=True,capture_output=True)
        self.assertEqual(1,result.returncode)
        self.assertTrue(result.stdout.startswith('CHECK_FAIL'))
        self.assertEqual('OLD_CONFIG',(self.sb/'reality_full.json').read_text())

    def test_watchdog_uses_http_without_icmp_gate(self):
        shutil.copy(ROOT/'runtime-lib.sh',self.sb/'runtime-lib.sh')
        self.script('service','echo service >> "$SBDIR/service.log"')
        (self.sb/'servers/test.json').write_text('{}')
        (self.sb/'postup.sh').write_text('exit 0')
        self.script('ping','exit 1')
        env=dict(self.env,SB_SERVICE=str(self.bin/'service'))
        subprocess.run(['sh',str(ROOT/'watchdog.sh')],env=env,check=True,capture_output=True)
        self.assertTrue((self.sb/'health').read_text().strip().endswith('|connected'))
        self.assertFalse((self.sb/'service.log').exists())

if __name__=='__main__':unittest.main()
