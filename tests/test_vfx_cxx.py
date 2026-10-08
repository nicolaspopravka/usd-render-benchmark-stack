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
VALIDATOR = ROOT / 'build-support/validate-build.sh'
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

    def fixture_compiler(self):
        compiler = self.directory / 'gcc-fixture'
        compiler.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                            'if "-dumpfullversion" in sys.argv: print("14.2.1")\n'
                            'elif "-dM" in sys.argv: print("#define __GNUC__ 14\\n#define _GLIBCXX_USE_CXX11_ABI 1")\n'
                            f'else: os.execv({shutil.which("c++")!r}, [{shutil.which("c++")!r}, *sys.argv[1:]])\n')
        compiler.chmod(0o755)
        return compiler

    def validate_build(self, source, command, compiler=None, **environment):
        evidence = source / 'evidence'
        return subprocess.run(['bash', str(VALIDATOR), 'fixture', str(source), str(source / 'build'),
                               'FixtureRenderer', *command],
                              env={**os.environ, 'VFX_PLATFORM_YEAR': '2026',
                                   'CXX': str(compiler or self.fixture_compiler()),
                                   'VFX_EVIDENCE_DIR': str(evidence), **environment}, text=True, capture_output=True)

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

    def test_conflicting_toolset_fails_before_activation(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_environment gcc-toolset-12',
                           VFX_PLATFORM_YEAR='2026', VFX_TOOLSET_ROOT=str(self.directory / 'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('conflicts with CY2026', result.stderr)
        self.assertNotIn('missing annual compiler', result.stderr)

    def test_missing_toolset_is_not_substituted(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_environment',
                           VFX_PLATFORM_YEAR='2026', VFX_TOOLSET_ROOT=str(self.directory / 'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing annual compiler', result.stderr)

    def test_missing_year_fails_environment_selection(self):
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_environment', VFX_PLATFORM_YEAR='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VFX_PLATFORM_YEAR', result.stderr)

    def test_toolset_activation_exports_environment(self):
        toolsets = self.directory / 'toolsets'
        toolset = toolsets / 'gcc-toolset-14'
        toolset.mkdir(parents=True)
        binaries = self.directory / 'bin'
        binaries.mkdir()
        for name in ['gcc', 'g++']:
            compiler = binaries / name
            compiler.write_text('#!/bin/sh\nexit 0\n')
            compiler.chmod(0o755)
        enable = toolset / 'enable'
        enable.write_text(f'export PATH="{binaries}:$PATH"\n')
        result = self.bash('set -euo pipefail; source "$1"; vfx_cxx_environment; '
                           'printf "%s %s %s" "$VFX_CXX_STANDARD" "$CC" "$CXX"',
                           VFX_PLATFORM_YEAR='2026', VFX_TOOLSET_ROOT=str(toolsets))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f'20 {binaries}/gcc {binaries}/g++')
        enable.write_text('return 31\n')
        failed = self.bash('set -euo pipefail; source "$1"; vfx_cxx_environment',
                           VFX_PLATFORM_YEAR='2026', VFX_TOOLSET_ROOT=str(toolsets))
        self.assertEqual(failed.returncode, 31)
        self.assertIn('activation failed', failed.stderr)

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

    def test_external_validator_retains_build_failure(self):
        result = self.validate_build(self.directory, ['bash', '-c', 'echo fixture-error >&2; exit 23'])
        self.assertEqual(result.returncode, 23)
        evidence = self.directory / 'evidence'
        self.assertIn('fixture-error', (evidence / 'build.log').read_text())
        self.assertIn('phase=build exit_status=23', (evidence / 'outcome.txt').read_text())

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
    def test_external_validator_real_build_failures(self):
        cases = [('configure', 'not_a_cmake_command()', 'int main() { return 0; }'),
                 ('compile', '', 'int main() { syntax error }'),
                 ('link', '', 'extern void missing(); int main() { missing(); }')]
        compiler = self.fixture_compiler()
        for label, cmake_error, code in cases:
            with self.subTest(label=label):
                source = self.directory / label
                source.mkdir()
                (source / 'main.cpp').write_text(code + '\n')
                (source / 'CMakeLists.txt').write_text(
                    'cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
                    'add_executable(fixture main.cpp)\n' + cmake_error + '\n')
                command = ['bash', '-euc', 'cmake -S "$1" -B "$1/build" '
                           '-DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_STANDARD_REQUIRED=ON '
                           '-DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; '
                           'cmake --build "$1/build" --verbose', 'fixture', str(source)]
                result = self.validate_build(source, command, compiler)
                self.assertNotEqual(result.returncode, 0)
                evidence = source / 'evidence'
                self.assertIn('phase=build', (evidence / 'outcome.txt').read_text())
                self.assertGreater((evidence / 'build.log').stat().st_size, 0)
                self.assertTrue((evidence / 'CMakeCache.txt').exists())
                if label != 'configure':
                    self.assertTrue((evidence / 'compile_commands.json').exists())
                    self.assertTrue((evidence / 'effective-settings.json').exists())

    def test_external_compiler_failure_prevents_builder(self):
        compiler = self.fixture_compiler()
        compiler.write_text(compiler.read_text().replace('14.2.1', '11.2.1'))
        result = self.validate_build(self.directory, ['touch', str(self.directory / 'built')], compiler)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / 'built').exists())
        self.assertIn('phase=compiler', (self.directory / 'evidence/outcome.txt').read_text())

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

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required for override fixture')
    def test_external_validator_rejects_project_override_after_build(self):
        (self.directory / 'main.cpp').write_text('int main() { return 0; }\n')
        (self.directory / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
            'set(CMAKE_CXX_STANDARD 17)\nadd_executable(fixture main.cpp)\n')
        result = self.validate_build(self.directory, ['bash', '-euc',
            'cmake -S "$1" -B "$1/build" -DCMAKE_CXX_STANDARD=20 '
            '-DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; '
            'cmake --build "$1/build"', 'fixture', str(self.directory)])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.directory / 'build/fixture').exists())
        self.assertIn('expected -std=c++20', result.stdout + result.stderr)
        phases = (self.directory / 'evidence/phases.log').read_text()
        self.assertIn('phase=settings exit_status=1', phases)
        self.assertNotIn('phase=loading', phases)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required for acceptance fixture')
    def test_external_validator_accepts_build_and_loading(self):
        (self.directory / 'main.cpp').write_text('int main() { return 0; }\n')
        (self.directory / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
            'add_executable(fixture main.cpp)\n')
        pxr = self.directory / 'pxr'
        pxr.mkdir()
        (pxr / '__init__.py').write_text(
            'class Plugin:\n name="fixture"\n path="/fixture/plugin.so"\n'
            ' def Load(self): return True\n'
            'class Registry:\n def GetPluginForType(self, type): return Plugin()\n'
            'class Plug:\n Registry=Registry\n'
            'class Type:\n @staticmethod\n def FindByName(name): return name\n'
            'class Tf:\n Type=Type\n')
        ldd = self.directory / 'ldd'
        ldd.write_text('#!/bin/sh\nexit 0\n')
        ldd.chmod(0o755)
        result = self.validate_build(self.directory, ['bash', '-euc',
            'cmake -S "$1" -B "$1/build" -DCMAKE_CXX_STANDARD=20 '
            '-DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_CXX_EXTENSIONS=OFF '
            '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON; cmake --build "$1/build"',
            'fixture', str(self.directory)], PYTHONPATH=str(self.directory),
            PATH=str(self.directory) + os.pathsep + os.environ['PATH'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        evidence = self.directory / 'evidence'
        self.assertIn('outcome=passed', (evidence / 'outcome.txt').read_text())
        self.assertIn('phase=loading exit_status=0', (evidence / 'phases.log').read_text())
        self.assertTrue((evidence / 'CMakeCache.txt').exists())
        self.assertTrue((evidence / 'compile_commands.json').exists())
        self.assertTrue((evidence / 'effective-settings.json').exists())
        self.assertTrue((self.directory / 'build/fixture').exists())

    def test_successful_builder_without_commands_fails_acceptance(self):
        result = self.validate_build(self.directory, ['bash', '-c', 'exit 0'])
        self.assertNotEqual(result.returncode, 0)
        phases = (self.directory / 'evidence/phases.log').read_text()
        self.assertIn('phase=settings exit_status=1', phases)
        self.assertNotIn('phase=loading', phases)


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

    def test_builders_only_configure_and_build(self):
        for builder in ROOT.glob('build_*.sh'):
            with self.subTest(builder=builder.name):
                text = builder.read_text()
                self.assertNotIn('vfx_', text)
                self.assertNotIn('build-support', text)
                self.assertNotIn('VFX_PLATFORM_YEAR', text)
                self.assertIn('-DCMAKE_CXX_STANDARD="${VFX_CXX_STANDARD:', text)
                self.assertIn('cmake --build ', text)
                self.assertIn('cmake --install ', text)

    def test_docker_invocation_propagates_validation_failure(self):
        dockerfile = (ROOT / 'Dockerfile.pristine').read_text()
        logical = dockerfile.replace('\\\n', '')
        commands = [line[4:] for line in logical.splitlines()
                    if line.startswith('RUN ') and 'validate-build.sh' in line]
        self.assertTrue(commands)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            support = directory / 'build-support'
            support.mkdir()
            (support / 'vfx-cxx.sh').write_text('vfx_cxx_environment() { export VFX_CXX_STANDARD=20; }\n')
            (support / 'validate-build.sh').write_text('echo fixture-validation-error >&2; exit 29\n')
            fixers = directory / 'moonray-fixers'
            fixers.mkdir()
            for name in ['01-gitlfs-prereqs.sh', '02-openusd-cmake-exports.sh',
                         '03-ispc.sh', '04-moonray-toolset.sh']:
                fixer = fixers / name
                fixer.write_text('#!/bin/sh\nexit 0\n')
                fixer.chmod(0o755)
            for name in ['build_moonray.sh', 'build_cycles.sh', 'build_hdembree.sh']:
                (directory / name).write_text('exit 0\n')
            env = {**os.environ, 'VFX_PLATFORM_YEAR': '2026', 'BASE_IMAGE': 'fixture',
                   'CYCLES_TAG': 'fixture', 'CYCLES_REPO': '', 'WITH_CYCLES_OSL': 'ON',
                   'WITH_CYCLES_OPENVDB': 'ON', 'MOONRAY_TAG': 'fixture', 'MOONRAY_REPO': '',
                   'MOONRAY_TOOLSET': '', 'OPENUSD_TAG': 'fixture'}
            for command in commands:
                with self.subTest(command=command[:50]):
                    root = directory / 'build-root'
                    root.mkdir(exist_ok=True)
                    marker = root / 'retained'
                    marker.touch()
                    command = command.replace('/usr/local/aswf', str(directory))
                    for original in ['/opt/build-cycles', '/opt/build-moonray', '/opt/build-hdembree']:
                        command = command.replace(original, str(root))
                    result = subprocess.run(['bash', '-c', command], env=env,
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
                    self.assertTrue(marker.exists(), 'cleanup must wait for validation')


if __name__ == '__main__':
    unittest.main()
