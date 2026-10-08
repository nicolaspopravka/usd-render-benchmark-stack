"""Local fixtures only: no delegate downloads, Docker builds or publication."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'build-support/vfx-cxx.sh'
CHECKER = ROOT / 'build-support/vfx_cxx.py'
spec = importlib.util.spec_from_file_location('vfx_cxx', CHECKER)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def bash(self, script, *args, **env):
        return subprocess.run(['bash', '-c', script, 'test', str(HELPER), *map(str, args)],
                              env={**os.environ, **env}, text=True, capture_output=True)

    def verify(self, entries, standard=20, compiler='/usr/bin/c++'):
        database = self.directory / 'compile_commands.json'
        database.write_text(json.dumps(entries))
        return subprocess.run(['python3', str(CHECKER), 'verify', '--database', str(database),
                               '--compiler', compiler, '--standard', str(standard),
                               '--output', str(self.directory / 'settings.json')],
                              text=True, capture_output=True)

    def entry(self, flags, source='fixture.cpp', compiler='/usr/bin/c++'):
        return {'directory': str(self.directory), 'file': source,
                'arguments': [compiler, *flags, '-c', source]}

    def test_years(self):
        for year in range(2023, 2028):
            with self.subTest(year=year):
                result = self.bash('source "$1"; vfx_select_year || exit; echo "$VFX_CXX_STANDARD $VFX_GCC_TOOLSET $VFX_GCC_RELEASE"',
                                   VFX_PLATFORM_YEAR=str(year))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '17 11 11.2' if year <= 2025 else '20 14 14.2')

    def test_invalid_years(self):
        for year in ['', '2022', '2028', '2025.3', '2026; exit 0']:
            with self.subTest(year=year):
                result = self.bash('source "$1"; vfx_select_year', VFX_PLATFORM_YEAR=year)
                self.assertNotEqual(result.returncode, 0)

    def test_requested_moonray_toolset(self):
        for year, requested, accepted in [('2025', '', True), ('2025', 'gcc-toolset-11', True),
                                          ('2026', 'gcc-toolset-14', True), ('2026', 'gcc-toolset-12', False),
                                          ('2027', 'gcc-toolset-11', False)]:
            with self.subTest(year=year, requested=requested):
                result = self.bash('source "$1"; vfx_select_year || exit; vfx_check_requested_toolset "$2"',
                                   requested, VFX_PLATFORM_YEAR=year)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_conflicting_toolset_retains_finding(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_init moonray',
                           VFX_PLATFORM_YEAR='2026', MOONRAY_TOOLSET='gcc-toolset-12',
                           VFX_EVIDENCE_DIR=str(self.directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('phase=toolset-request', (self.directory / 'outcome.txt').read_text())
        self.assertIn('conflicts with CY2026', result.stdout)

    def test_missing_toolset_preserves_finding(self):
        if Path('/opt/rh/gcc-toolset-14/enable').exists():
            self.skipTest('fixture expects no Linux Software Collections on this host')
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_init fixture',
                           VFX_PLATFORM_YEAR='2026', VFX_EVIDENCE_DIR=str(self.directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('phase=toolset', (self.directory / 'outcome.txt').read_text())
        self.assertIn('cxx_standard=20', result.stdout)

    def test_missing_year_preserves_finding(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_init fixture',
                           VFX_PLATFORM_YEAR='', VFX_EVIDENCE_DIR=str(self.directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('phase=year', (self.directory / 'outcome.txt').read_text())

    def test_toolset_activation_and_cmake_arguments(self):
        toolsets = self.directory / 'toolsets'
        toolset = toolsets / 'gcc-toolset-14'
        toolset.mkdir(parents=True)
        binaries = self.directory / 'bin'
        binaries.mkdir()
        for name in ['gcc', 'g++']:
            compiler = binaries / name
            compiler.write_text('#!/usr/bin/env python3\nimport sys\n'
                                'print("14.2.1" if "-dumpfullversion" in sys.argv else '
                                '"#define __GNUC__ 14\\n#define _GLIBCXX_USE_CXX11_ABI 1")\n')
            compiler.chmod(0o755)
        enable = toolset / 'enable'
        enable.write_text(f'export PATH="{binaries}:$PATH"\n')
        evidence = self.directory / 'evidence'
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_init fixture; printf "%s\\n" "${VFX_CMAKE_ARGS[@]}"',
                           VFX_PLATFORM_YEAR='2026', VFX_EVIDENCE_DIR=str(evidence),
                           VFX_TOOLSET_ROOT=str(toolsets))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DCMAKE_CXX_STANDARD=20', result.stdout)
        self.assertIn('-DCMAKE_CXX_STANDARD_REQUIRED=ON', result.stdout)
        self.assertIn('-DCMAKE_CXX_EXTENSIONS=OFF', result.stdout)
        self.assertIn('-DCMAKE_CXX_COMPILER=' + str(binaries / 'g++'), result.stdout)
        self.assertEqual(json.loads((evidence / 'compiler.json').read_text())['version'], '14.2.1')
        enable.write_text('return 31\n')
        failed = self.bash('set -euo pipefail; source "$1"; vfx_cxx_init fixture',
                           VFX_PLATFORM_YEAR='2026', VFX_EVIDENCE_DIR=str(evidence),
                           VFX_TOOLSET_ROOT=str(toolsets))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('activation-failed', (evidence / 'outcome.txt').read_text())

    def test_standard_and_abi(self):
        for standard in [17, 20]:
            result = self.verify([self.entry([f'-std=c++{standard}', '-D_GLIBCXX_USE_CXX11_ABI=1'])], standard)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_overrides_and_fallback(self):
        for flags in [[], ['-std=c++17'], ['-std=c++20', '-std=c++17'],
                      ['-std=gnu++20'], ['-std=c++23'],
                      ['-std=c++20', '-D_GLIBCXX_USE_CXX11_ABI=0'],
                      ['-std=c++20', '-D', '_GLIBCXX_USE_CXX11_ABI=0'],
                      ['-std=c++20', '-U_GLIBCXX_USE_CXX11_ABI']]:
            with self.subTest(flags=flags):
                result = self.verify([self.entry(flags)])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('fixture.cpp', result.stderr)
                self.assertIn('command:', result.stderr)

    def test_compiler_mismatch(self):
        result = self.verify([self.entry(['-std=c++20'], compiler='/another/compiler')])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compiler differs', result.stderr)

    def test_cuda_and_c_are_separate(self):
        result = self.verify([self.entry(['-std=c++17'], 'kernel.cu', 'nvcc'),
                              self.entry([], 'fixture.c', 'cc'), self.entry(['-std=c++20'])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['other_commands'], 2)

    def test_no_host_commands_is_not_success(self):
        result = self.verify([self.entry(['-std=c++17'], 'kernel.cu', 'nvcc')])
        self.assertNotEqual(result.returncode, 0)

    def test_launcher_and_response_file(self):
        (self.directory / 'flags.rsp').write_text('-std=c++20 -D_GLIBCXX_USE_CXX11_ABI=1')
        entry = self.entry(['@flags.rsp'])
        entry['arguments'].insert(0, 'ccache')
        result = self.verify([entry])
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.directory / 'flags.rsp').write_text('-std=c++17')
        self.assertNotEqual(self.verify([entry]).returncode, 0)

    def test_missing_and_recursive_response_files(self):
        self.assertNotEqual(self.verify([self.entry(['@missing.rsp'])]).returncode, 0)
        (self.directory / 'flags.rsp').write_text('@flags.rsp')
        result = self.verify([self.entry(['@flags.rsp'])])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('recursive response file', result.stderr)

    def test_compiler_identity_and_abi_probe(self):
        compiler = self.directory / 'gcc-fixture'
        for version, macros, accepted in [
            ('14.2.1', '#define __GNUC__ 14\n#define _GLIBCXX_USE_CXX11_ABI 1', True),
            ('11.2.1', '#define __GNUC__ 11\n#define _GLIBCXX_USE_CXX11_ABI 1', False),
            ('14.2.1', '#define __GNUC__ 14\n#define _GLIBCXX_USE_CXX11_ABI 0', False),
            ('14.2.1', '#define __GNUC__ 14\n#define __clang__ 1\n#define _GLIBCXX_USE_CXX11_ABI 1', False),
        ]:
            compiler.write_text('#!/usr/bin/env python3\nimport sys\n'
                                f'print({version!r} if "-dumpfullversion" in sys.argv else {macros!r})\n')
            compiler.chmod(0o755)
            result = subprocess.run(['python3', str(CHECKER), 'compiler', '--compiler', str(compiler),
                                     '--release', '14.2', '--output', str(self.directory / 'compiler.json')],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_runner_retains_status_and_output(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_run compile-link bash -c "echo fixture-error >&2; exit 23"',
                           VFX_EVIDENCE_DIR=str(self.directory))
        self.assertEqual(result.returncode, 23)
        self.assertIn('fixture-error', (self.directory / 'compile-link.log').read_text())
        self.assertIn('exit_status=23', (self.directory / 'outcome.txt').read_text())

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required for real configure/build fixtures')
    def test_real_cmake_settings(self):
        for override in ['', 'set(CMAKE_CXX_STANDARD 17)',
                         'set_property(TARGET fixture PROPERTY CXX_STANDARD 17)',
                         'target_compile_options(fixture PRIVATE -std=c++17)']:
            with self.subTest(override=override):
                source = self.directory / ('source-' + str(len(list(self.directory.iterdir()))))
                source.mkdir()
                (source / 'main.cpp').write_text('int main() { return 0; }\n')
                prefix = override if override.startswith('set(') else ''
                suffix = override if not prefix else ''
                (source / 'CMakeLists.txt').write_text(
                    'cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
                    + prefix + '\nadd_executable(fixture main.cpp)\n' + suffix + '\n')
                build = source / 'build'
                result = subprocess.run(['cmake', '-S', str(source), '-B', str(build),
                                         '-DCMAKE_CXX_STANDARD=20', '-DCMAKE_CXX_STANDARD_REQUIRED=ON',
                                         '-DCMAKE_CXX_EXTENSIONS=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                entries = json.loads((build / 'compile_commands.json').read_text())
                compiler = __import__('shlex').split(entries[0]['command'])[0]
                verified = self.verify(entries, compiler=compiler)
                self.assertEqual(verified.returncode == 0, not override, verified.stderr)
                if not override:
                    built = subprocess.run(['cmake', '--build', str(build)], text=True, capture_output=True)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    self.assertEqual(subprocess.run([str(build / 'fixture')]).returncode, 0)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required for failure fixtures')
    def test_real_configure_compile_and_link_failures(self):
        cases = [('configure', 'not_a_cmake_command()', 'int main() { return 0; }'),
                 ('compile', '', 'int main() { syntax error }'),
                 ('link', '', 'extern void missing(); int main() { missing(); }')]
        for label, cmake_error, code in cases:
            with self.subTest(label=label):
                source = self.directory / label
                source.mkdir()
                (source / 'main.cpp').write_text(code + '\n')
                (source / 'CMakeLists.txt').write_text(
                    'cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
                    'add_executable(fixture main.cpp)\n' + cmake_error + '\n')
                evidence = source / 'evidence'
                evidence.mkdir()
                result = self.bash(
                    'set -euo pipefail; source "$1"; vfx_configure "$2/build" cmake -S "$2" -B "$2/build"; '
                    'vfx_run compile-link cmake --build "$2/build" --verbose', source,
                    VFX_EVIDENCE_DIR=str(evidence))
                self.assertNotEqual(result.returncode, 0)
                expected_phase = 'configure' if label == 'configure' else 'compile-link'
                self.assertIn('phase=' + expected_phase, (evidence / 'outcome.txt').read_text())
                self.assertGreater((evidence / (expected_phase + '.log')).stat().st_size, 0)
                self.assertTrue((evidence / 'CMakeCache.txt').exists())

    def test_preparation_failure_is_retained(self):
        (self.directory / 'outcome.txt').write_text('outcome=incomplete\n')
        result = self.bash('set -euo pipefail; source "$1"; trap \'vfx_finish "$?"\' EXIT; exit 19',
                           VFX_EVIDENCE_DIR=str(self.directory))
        self.assertEqual(result.returncode, 19)
        self.assertIn('phase=preparation exit_status=19', (self.directory / 'outcome.txt').read_text())

    def test_loading_and_unresolved_symbol_findings(self):
        pxr = Mock()
        plugin = pxr.Plug.Registry.return_value.GetPluginForType.return_value
        plugin.path = '/fixture/hdExample.so'
        plugin.name = 'example'
        plugin.Load.return_value = True
        args = Mock(type='ExampleRenderer')
        with patch.dict('sys.modules', {'pxr': pxr}):
            with patch.object(checker.subprocess, 'run', return_value=Mock(returncode=0, stdout='', stderr='')):
                self.assertTrue(checker.load_plugin(args)['loaded'])
                plugin.Load.return_value = False
                with self.assertRaisesRegex(ValueError, 'plugin loading failed'):
                    checker.load_plugin(args)
            plugin.Load.reset_mock()
            with patch.object(checker.subprocess, 'run', return_value=Mock(returncode=0, stdout='undefined symbol: fixture', stderr='')):
                with self.assertRaisesRegex(ValueError, 'unresolved dependencies'):
                    checker.load_plugin(args)
                plugin.Load.assert_not_called()


class WiringTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('ruby'), 'Ruby YAML parser required for workflow fixtures')
    def test_workflow_command_forwarding_and_failure(self):
        workflow = ROOT / '.github/workflows/build-pristine.yml'
        parsed = subprocess.run(['ruby', '-ryaml', '-rjson', '-e',
                                 'puts JSON.generate(YAML.load_file(ARGV[0]))', str(workflow)],
                                text=True, capture_output=True)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        document = json.loads(parsed.stdout)
        # YAML 1.1 reads the unquoted GitHub Actions `on` key as boolean true.
        trigger = document.get('on', document.get('true'))
        year = trigger['workflow_dispatch']['inputs']['vfx_platform_year']
        self.assertEqual(year['options'], [str(y) for y in range(2023, 2028)])
        self.assertTrue(year['required'])
        steps = document['jobs']['build']['steps']
        build = next(step for step in steps if step.get('name') == 'Build + push pristine')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            docker = directory / 'docker'
            docker.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                              'print(json.dumps(sys.argv[1:]))\nsys.exit(27)\n')
            docker.chmod(0o755)
            env = {**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                   'BASE_IMAGE': 'fixture@sha256:base', 'VFX_PLATFORM_YEAR': '2026',
                   'CYCLES_TAG': 'fixture', 'OPENUSD_TAG': 'fixture', 'MOONRAY_TAG': 'fixture',
                   'CYCLES_REPO': 'https://fixture/cycles', 'MOONRAY_REPO': 'https://fixture/moonray',
                   'MOONRAY_TOOLSET': 'gcc-toolset-14',
                   'WITH_CYCLES_OSL': 'ON', 'WITH_CYCLES_OPENVDB': 'ON',
                   'IMAGE_TAG': 'fixture', 'IMAGE_VERSION': '', 'PRISTINE_IMAGE': 'fixture'}
            result = subprocess.run(['bash', '-c', build['run']], cwd=directory,
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 27, result.stderr)
            arguments = json.loads((directory / 'build-pristine.log').read_text())
            self.assertIn('VFX_PLATFORM_YEAR=2026', arguments)
            self.assertIn('--progress=plain', arguments)
            for field in ['cycles_repo', 'moonray_repo', 'moonray_toolset']:
                if field in trigger['workflow_dispatch']['inputs']:
                    self.assertIn(field.upper() + '=' + env[field.upper()], arguments)

    def test_workflow_and_dockerfile(self):
        workflow = (ROOT / '.github/workflows/build-pristine.yml').read_text()
        self.assertIn('vfx_platform_year:', workflow)
        self.assertIn('VFX_PLATFORM_YEAR: ${{ inputs.vfx_platform_year }}', workflow)
        self.assertIn('--build-arg VFX_PLATFORM_YEAR="$VFX_PLATFORM_YEAR"', workflow)
        self.assertIn('--progress=plain', workflow)
        self.assertIn('if: always()', workflow)
        dockerfile = (ROOT / 'Dockerfile.pristine').read_text()
        self.assertIn('FROM ${BASE_IMAGE}\nARG BASE_IMAGE', dockerfile)
        self.assertIn('ARG VFX_PLATFORM_YEAR', dockerfile)
        self.assertIn('COPY build-support/ /usr/local/aswf/build-support/', dockerfile)
        self.assertIn('VFX_PLATFORM_YEAR="${VFX_PLATFORM_YEAR}"', dockerfile)
        self.assertIn('VFX_BASE_IMAGE="${BASE_IMAGE}"', dockerfile)

    def test_builder_gates_before_compile(self):
        builders = list(ROOT.glob('build_*.sh'))
        self.assertTrue(builders)
        for builder in builders:
            text = builder.read_text()
            self.assertIn('vfx_cxx_init', text)
            self.assertIn('"${VFX_CMAKE_ARGS[@]}"', text)
            self.assertLess(text.index('vfx_verify_commands'), text.index('vfx_run compile-link'))
            self.assertLess(text.index('vfx_check_plugin'), text.index('vfx_complete'))


if __name__ == '__main__':
    unittest.main()
