import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_pair', Path(__file__).with_name('build_pair.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class ValidationTests(unittest.TestCase):
    def test_frozen_manifest_covers_fifteen_pairs(self):
        m = json.loads(build.MANIFEST.read_text())
        self.assertEqual([(p['delegate'], p['year']) for p in m['pairs']],
                         [(d, y) for d in ['embree', 'cycles', 'moonray'] for y in range(2023, 2028)])
        for p in m['pairs']:
            self.assertRegex(p['base_image'], r'@sha256:[a-f0-9]{64}$')
            for commit in [p['source']['commit'], *p['recipe'].values()]:
                self.assertRegex(commit, r'^[a-f0-9]{40}$')
            if p['delegate'] == 'cycles':
                self.assertEqual(p['build_args']['MOONRAY_TAG'], '')
            if p['delegate'] == 'moonray':
                self.assertEqual(p['build_args']['CYCLES_TAG'], '')
        self.assertEqual(m['platform'], 'linux/amd64')

    def test_commands_change_only_profile_with_no_export(self):
        for p in json.loads(build.MANIFEST.read_text())['pairs']:
            a = build.command(p, 'off', 'recipe')
            b = build.command(p, str(p['year']), 'recipe')
            differences = [(x, y) for x, y in zip(a, b) if x != y]
            self.assertEqual(differences, [('CXX_CONFORMANCE=off', f'CXX_CONFORMANCE={p["year"]}')])
            self.assertNotIn('--push', a)
            self.assertNotIn('--load', a)
            self.assertIn('type=cacheonly', a)

    def fixture(self, codes):
        pair, _ = build.load_pair('embree-2026')
        invoked = []
        def popen(args, stdout, **kwargs):
            invoked.append(args)
            code = codes[len(invoked) - 1]
            stdout.write(pair['source']['commit'] + '\n')
            stdout.write('CMake Error: fixture existing dependency\n' if code else '"host_cxx_commands": 12\n')
            stdout.flush()
            class Process:
                pid = 987654
                def wait(self, **kwargs):
                    return code
            return Process()
        return pair, invoked, popen

    def test_failed_off_gets_baseline_and_on_still_runs(self):
        pair, invoked, popen = self.fixture([7, 0, 9])
        with tempfile.TemporaryDirectory() as temp, patch.object(build, 'source_commit', return_value=pair['source']['commit']), patch.object(build.subprocess, 'Popen', side_effect=popen), contextlib.redirect_stdout(io.StringIO()):
            code = build.run_pair(pair['id'], 'recipe', 'baseline', temp)
            result = json.loads((Path(temp) / 'result.json').read_text())
            self.assertEqual(code, 1)
            self.assertEqual([r['label'] for r in result['attempts']], ['off', 'baseline-off', 'on'])
            self.assertEqual([r['exit_status'] for r in result['attempts']], [7, 0, 9])
            self.assertIn('possible regression', result['off_comparison'])
            self.assertTrue(all((Path(temp) / r['log']).exists() for r in result['attempts']))
            self.assertEqual(invoked[1][-1], 'baseline')

    def test_success_does_not_rebuild_baseline(self):
        pair, invoked, popen = self.fixture([0, 0])
        with tempfile.TemporaryDirectory() as temp, patch.object(build, 'source_commit', return_value=pair['source']['commit']), patch.object(build.subprocess, 'Popen', side_effect=popen), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.run_pair(pair['id'], 'recipe', 'baseline', temp), 0)
            self.assertEqual(len(invoked), 2)

    def test_source_drift_is_not_silently_accepted(self):
        pair, _, _ = self.fixture([])
        with tempfile.TemporaryDirectory() as temp, patch.object(build, 'source_commit', return_value='0' * 40), patch.object(build.subprocess, 'Popen') as process, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.run_pair(pair['id'], 'recipe', 'baseline', temp), 1)
            process.assert_not_called()
            result = json.loads((Path(temp) / 'result.json').read_text())
            self.assertTrue(all('source ref drift' in r['diagnostic'] for r in result['attempts']))

    def test_profile_and_infrastructure_are_distinct(self):
        self.assertEqual(build.classify(1, 'ERROR: requested toolset gcc-toolset-12 conflicts with CY2026', '2026'), 'compiler/profile rejection')
        self.assertEqual(build.classify(124, '', 'off'), 'infrastructure interruption')
        self.assertEqual(build.classify(1, 'no space left on device', 'off'), 'infrastructure interruption')
        self.assertEqual(build.classify(0, '', '2026'), 'missing profile evidence')
        self.assertEqual(build.classify(1, 'CMake Error: missing dependency', 'off'), 'configure failure')
        self.assertEqual(build.classify(1, 'undefined reference to fixture', 'off'), 'link failure')

    def test_report_preserves_missing_attempts(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()) as text:
            build.report(build.MANIFEST, temp)
            self.assertEqual(text.getvalue().count('Not recorded'), 30)

    def test_workflow_is_serial_and_artifacts_survive_failures(self):
        root = Path(__file__).parents[1]
        workflow = (root / '.github/workflows/annual-cxx-build-only.yml').read_text()
        pairs = json.loads(build.MANIFEST.read_text())['pairs']
        previous = 'fixtures'
        for p in pairs:
            job = p['id'].replace('-', '_')
            self.assertIn(f'  {job}:\n    needs: {previous}', workflow)
            previous = job
        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        reusable = (root / '.github/workflows/annual-cxx-pair.yml').read_text()
        self.assertIn('if: always()', reusable)
        self.assertNotIn('packages: write', reusable)
        self.assertNotIn('login-action', reusable)
        self.assertNotIn('setup-buildx-action', reusable)
        self.assertIn('DOCKER_CONFIG: ${{ runner.temp }}/cxx-docker-config', reusable)
        self.assertIn('cp validation/annual-inputs.json results/manifest.json', reusable)


if __name__ == '__main__':
    unittest.main()
