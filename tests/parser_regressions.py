import base64
import json
import pathlib
import subprocess
import sys
import unittest

PARSER = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1] / 'parse-link.sh'


class ParserTests(unittest.TestCase):
    def parse(self, link):
        result = subprocess.run(['sh', str(PARSER), link, 'test'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_encoded_passwords(self):
        for scheme in ['trojan', 'hy2', 'hysteria2']:
            with self.subTest(scheme=scheme):
                out = self.parse(f'{scheme}://hello%40world+%3A%25@example.com:443?sni=example.com')
                self.assertEqual(out['password'], 'hello@world+:%')
                self.assertEqual(out['server'], 'example.com')

    def test_tuic_components(self):
        out = self.parse('tuic://test-uuid:hello%40world+%3A%25@example.com:443')
        self.assertEqual(out['uuid'], 'test-uuid')
        self.assertEqual(out['password'], 'hello@world+:%')

    def test_legacy_shadowsocks(self):
        for host in ['example.com', '[2001:db8::1]']:
            raw = f'aes-256-gcm:p@ss+%40:{host}@{host}:443'
            body = base64.b64encode(raw.encode()).decode().rstrip('=')
            out = self.parse(f'ss://{body}#name')
            self.assertEqual(out['password'], f'p@ss+%40:{host}')
            self.assertEqual(out['server'], host.strip('[]'))
            self.assertEqual(out['server_port'], 443)

    def test_sip002(self):
        auth = base64.urlsafe_b64encode(b'aes-256-gcm:p@ss+%40').decode().rstrip('=')
        out = self.parse(f'ss://{auth}@example.com:443#name')
        self.assertEqual(out['password'], 'p@ss+%40')

    def test_plain_shadowsocks(self):
        out = self.parse('ss://aes-256-gcm:p%40ss+%2540@example.com:443')
        self.assertEqual(out['password'], 'p@ss+%40')

    def test_existing_protocols(self):
        out = self.parse('vless://test-uuid@example.com:443?security=tls&type=ws&path=%2Ftest&host=cdn.example.com')
        self.assertEqual(out['uuid'], 'test-uuid')
        self.assertEqual(out['transport']['path'], '/test')
        self.assertEqual(out['transport']['headers']['Host'], 'cdn.example.com')
        out = self.parse('hy2://secret@[2001:db8::1]:8443/?sni=example.com')
        self.assertEqual(out['server_port'], 8443)
        self.assertEqual(out['tls']['server_name'], 'example.com')
        auth = base64.b64encode(json.dumps({'add': 'example.com', 'port': '443', 'id': 'test-uuid', 'net': 'tcp', 'tls': 'tls'}).encode()).decode()
        out = self.parse(f'vmess://{auth}')
        self.assertEqual(out['type'], 'vmess')
        self.assertEqual(out['server_port'], 443)

    def test_invalid_legacy(self):
        result = subprocess.run(['sh', str(PARSER), 'ss://invalid', 'test'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
