import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.servers = self.root / 'servers'
        self.servers.mkdir()
        self.env = dict(os.environ, SBDIR=str(self.root))
        shutil.copy(ROOT / 'parse-link.sh', self.root / 'parse-link.sh')
        (self.root / 'rebuild.sh').write_text('#!/bin/sh\necho "${TEST_REBUILD:-OK}"\n')
        self.old = self.servers / 'home.json'
        self.old.write_text('{"tag":"home","type":"direct"}\n')

    def run_script(self, name, *args):
        return subprocess.run(['sh', str(ROOT / name), *args], env=self.env, text=True, capture_output=True)

    def test_duplicate_add_preserves_original(self):
        original = self.old.read_bytes()
        result = self.run_script('add-server.sh', 'trojan://password@example.com:443', 'home')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.old.read_bytes(), original)
        self.assertEqual(json.loads((self.servers / 'home-1.json').read_text())['tag'], 'home-1')

    def test_add_rejection_preserves_original(self):
        self.env['TEST_REBUILD'] = 'CHECK_FAIL'
        result = self.run_script('add-server.sh', 'trojan://password@example.com:443', 'home')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(p.name for p in self.servers.iterdir()), ['home.json'])

    def test_delete_rolls_back(self):
        self.env['TEST_REBUILD'] = 'CHECK_FAIL'
        original = self.old.read_bytes()
        result = self.run_script('del-server.sh', 'home')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.old.read_bytes(), original)
        self.assertFalse((self.root / '.servers.lock').exists())

    def test_busy_lock_blocks_both_writers(self):
        (self.root / '.servers.lock').mkdir()
        original = self.old.read_bytes()
        for name, args in [('add-server.sh', ('trojan://password@example.com:443', 'home')), ('del-server.sh', ('home',))]:
            result = self.run_script(name, *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already running', result.stderr)
            self.assertEqual(self.old.read_bytes(), original)

    def test_interruption_rolls_back(self):
        (self.root / 'rebuild.sh').write_text('#!/bin/sh\nif [ ! -f "$SBDIR/ready" ]; then touch "$SBDIR/ready"; sleep 1; fi\necho OK\n')
        original = self.old.read_bytes()
        for name, args in [('add-server.sh', ('trojan://password@example.com:443', 'home')), ('del-server.sh', ('home',))]:
            (self.root / 'ready').unlink(missing_ok=True)
            process = subprocess.Popen(['sh', str(ROOT / name), *args], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 5
            while not (self.root / 'ready').exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.root / 'ready').exists())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(self.old.read_bytes(), original)
            self.assertEqual(sorted(p.name for p in self.servers.iterdir()), ['home.json'])
            self.assertFalse((self.root / '.servers.lock').exists())

    def test_invalid_tag_rejected(self):
        for name, args in [('add-server.sh', ('trojan://password@example.com:443', '../other')), ('del-server.sh', ('../other',))]:
            self.assertNotEqual(self.run_script(name, *args).returncode, 0)


if __name__ == '__main__':
    unittest.main()
