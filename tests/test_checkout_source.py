"""Exercise source resolution against a real local Git remote."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKOUT = ROOT / 'build-support/checkout-source.sh'


class CheckoutSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.remote = self.root / 'remote'
        self.git('init', '-b', 'main', str(self.remote))
        self.git('-C', str(self.remote), 'config', 'user.name', 'Source fixture')
        self.git('-C', str(self.remote), 'config', 'user.email', 'fixture@local')
        (self.remote / 'content').write_text('first\n')
        self.git('-C', str(self.remote), 'add', 'content')
        self.git('-C', str(self.remote), 'commit', '-m', 'First')
        self.first = self.git('-C', str(self.remote), 'rev-parse', 'HEAD').strip()
        self.git('-C', str(self.remote), 'tag', 'v1')
        (self.remote / 'content').write_text('second\n')
        self.git('-C', str(self.remote), 'commit', '-am', 'Second')
        self.second = self.git('-C', str(self.remote), 'rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True,
                                       stderr=subprocess.STDOUT)

    def checkout(self, ref, destination):
        return subprocess.run(['bash', str(CHECKOUT), str(self.remote), ref,
                               str(destination)], text=True, capture_output=True)

    def test_pin_remains_exact_when_branch_has_advanced(self):
        destination = self.root / 'pinned'
        result = self.checkout(self.first, destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('-C', str(destination), 'rev-parse', 'HEAD').strip(),
                         self.first)
        self.assertEqual((destination / 'content').read_text(), 'first\n')
        self.assertIn(self.first, result.stdout)

    def test_legacy_tag_and_branch_still_resolve(self):
        for ref, expected in [('v1', self.first), ('main', self.second)]:
            with self.subTest(ref=ref):
                destination = self.root / ref
                result = self.checkout(ref, destination)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git('-C', str(destination), 'rev-parse', 'HEAD').strip(),
                                 expected)

    def test_missing_ref_fails_without_fallback(self):
        for ref in ['missing-tag', '0' * 40]:
            with self.subTest(ref=ref):
                result = self.checkout(ref, self.root / ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Source:', result.stdout)

    def test_existing_destination_is_preserved(self):
        result = self.checkout('v1', self.remote)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.remote / 'content').read_text(), 'second\n')

    def test_cycles_builder_rejects_noncommit_ref_before_checkout(self):
        environment = dict(os.environ, CYCLES_REF='main')
        result = subprocess.run(['bash', str(ROOT / 'build_cycles.sh')],
                                env=environment, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be a full lowercase commit ID', result.stderr)


if __name__ == '__main__':
    unittest.main()
