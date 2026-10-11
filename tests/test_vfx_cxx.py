"""Local fixtures only: no renderer downloads, images, dispatch or publication."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'build-support/vfx-cxx.sh'
CHECKER = ROOT / 'build-support/vfx_cxx.py'

class Fixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.toolsets = self.directory / 'toolsets'
        actual = shutil.which('c++')
        for year in [11, 12, 14]:
            toolset = self.toolsets / f'gcc-toolset-{year}'
            binaries = toolset / 'bin'
            binaries.mkdir(parents=True)
            for name in ['gcc', 'g++']:
                compiler = binaries / name
                compiler.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                    'if "FIXTURE_COMPILER_LOG" in os.environ:\n'
                    ' with open(os.environ["FIXTURE_COMPILER_LOG"], "a") as log: log.write("called\\n")\n'
                    'if "-dumpfullversion" in sys.argv: print(os.getenv("FIXTURE_GCC_VERSION", "14.2.1"))\n'
                    'elif "-dM" in sys.argv:\n'
                    ' print("#define __GNUC__ 14\\n#define _GLIBCXX_USE_CXX11_ABI " + os.getenv("FIXTURE_ABI", "1") + "\\n#define __cplusplus " + os.getenv("FIXTURE_DEFAULT_CPP", "201703L"))\n'
                    ' if os.getenv("FIXTURE_CLANG"): print("#define __clang__ 1")\n'
                    f'else: os.execv({actual!r}, [{actual!r}, *sys.argv[1:]])\n')
                compiler.chmod(0o755)
            installed=toolset/'root/usr/bin'
            installed.mkdir(parents=True)
            for name in ['gcc','g++']: (installed/name).symlink_to(binaries/name)
            (toolset / 'enable').write_text(f'export PATH="{binaries}:$PATH"\n')
        self.compiler = self.toolsets / 'gcc-toolset-14/bin/g++'

    def tearDown(self):
        self.temp.cleanup()

    def bash(self, command, **env):
        return subprocess.run(['bash', '-c', command, 'fixture', str(HELPER)],
            env={**os.environ, 'VFX_TOOLSET_ROOT': str(self.toolsets), **env}, text=True, capture_output=True)

    def probe(self, **env):
        return subprocess.run(['python3', str(CHECKER), 'compiler', '--compiler', str(self.compiler),
            '--release', '14.2'], env={**os.environ, **env}, text=True, capture_output=True)

    def test_year_profiles(self):
        for year in range(2023, 2028):
            with self.subTest(year=year):
                result = self.bash('source "$1"; vfx_select_year; echo "$VFX_CXX_STANDARD $VFX_GCC_TOOLSET $VFX_GCC_RELEASE"',
                                   CXX_CONFORMANCE=str(year))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '17 11 11.2' if year <= 2025 else '20 14 14.2')

    def test_off_and_omitted_preserve_compiler_and_cuda_choices(self):
        for mode in [None, 'off']:
            env = {'CC': 'chosen-c', 'CXX': 'chosen-cxx', 'CUDA_HOST_COMPILER': 'cuda-gcc-12',
                   'VFX_CXX_STANDARD': '20', 'VFX_TOOLSET_ROOT': '/missing',
                   'FIXTURE_COMPILER_LOG': str(self.directory / 'calls')}
            if mode is not None: env['CXX_CONFORMANCE'] = mode
            result = self.bash('source "$1"; vfx_cxx_environment gcc-toolset-12 || exit; '
                'printf "%s|%s|%s|%s" "$CC" "$CXX" "$CUDA_HOST_COMPILER" "${VFX_CXX_STANDARD:-}"', **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'chosen-c|chosen-cxx|cuda-gcc-12|')
            self.assertFalse((self.directory / 'calls').exists())

    def test_invalid_modes(self):
        for mode in ['', '2022', '2028', '2026.3', 'true', '2026; exit 0']:
            result = self.bash('source "$1"; vfx_select_year', CXX_CONFORMANCE=mode)
            # Empty Docker input follows the omitted/default-off behavior.
            self.assertEqual(result.returncode == 0, mode == '', result.stderr)

    def test_enabled_missing_toolset_is_a_finding(self):
        result = self.bash('source "$1"; vfx_cxx_environment', CXX_CONFORMANCE='2026', VFX_TOOLSET_ROOT='/missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing annual compiler', result.stderr)

    def test_enabled_activation_and_separate_cuda(self):
        for mode, version, toolset in [('2025', '11.2.1', 11), ('2026', '14.2.1', 14)]:
            result = self.bash('source "$1"; vfx_cxx_environment || exit; echo "$CXX|$CUDA_HOST_COMPILER|$VFX_CXX_STANDARD"',
                CXX_CONFORMANCE=mode, FIXTURE_GCC_VERSION=version, CUDA_HOST_COMPILER='cuda-gcc-12')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'gcc-toolset-{toolset}/bin/g++|cuda-gcc-12|', result.stdout)

    def test_activation_failure_keeps_status(self):
        (self.toolsets / 'gcc-toolset-14/enable').write_text('return 31\n')
        result = self.bash('source "$1"; vfx_cxx_environment', CXX_CONFORMANCE='2026')
        self.assertEqual(result.returncode, 31)

    def test_compiler_release_abi_and_identity(self):
        for env, accepted in [({}, True), ({'FIXTURE_GCC_VERSION': '11.2.1'}, False),
                              ({'FIXTURE_ABI': '0'}, False), ({'FIXTURE_CLANG': '1'}, False)]:
            with self.subTest(env=env):
                result = self.probe(**env)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

class RecipeTests(unittest.TestCase):
    setUp = Fixtures.setUp
    tearDown = Fixtures.tearDown
    def test_default_builder_commands_match_established_recipes(self):
        base = '5737db1f157b395c658d7b5e448976174ea18a1b'
        binaries = self.directory / 'stubs'
        binaries.mkdir()
        for name in ['git', 'cmake', 'dnf', 'rpm', 'nproc']:
            command = binaries / name
            command.write_text('#!/usr/bin/env python3\nimport json,os,sys,pathlib\n'
                'name=pathlib.Path(sys.argv[0]).name\n'
                'with open(os.environ["FIXTURE_LOG"],"a") as log: log.write(json.dumps([name,*sys.argv[1:]])+"\\n")\n'
                'if name=="git" and "clone" in sys.argv: pathlib.Path(sys.argv[-1]).mkdir(parents=True)\n'
                'elif name=="git" and "rev-parse" in sys.argv: print("fixture-sha")\n'
                'elif name=="cmake" and "--version" in sys.argv: print("cmake version 4.4.2")\n'
                'elif name=="nproc": print("2")\n')
            command.chmod(0o755)
        for builder in ROOT.glob('build_*.sh'):
            logs=[]
            for variant in ['base', 'current']:
                text = subprocess.check_output(['git','-C',str(ROOT),'show',f'{base}:{builder.name}'],text=True) if variant=='base' else builder.read_text()
                build = self.directory / f'{builder.stem}-{variant}'
                text = text.replace('/opt/build-cycles',str(build))
                script = self.directory / f'{builder.stem}-{variant}.sh'
                script.write_text(text)
                log = self.directory / f'{builder.stem}-{variant}.log'
                env={**os.environ,'PATH':str(binaries)+os.pathsep+os.environ['PATH'], 'FIXTURE_LOG':str(log),
                     'CYCLES_TAG':'fixture','MOONRAY_TAG':'fixture','OPENUSD_TAG':'fixture',
                     'MOONRAY_BUILD_ROOT':str(build),'HDEMBREE_BUILD_ROOT':str(build),
                     'ASWF_INSTALL_PREFIX':'/fixture/install','ASWF_PYTHON_MAJOR_MINOR_VERSION':'3.11',
                     'CUDA_HOST_COMPILER':'chosen-cuda-compiler'}
                env.pop('VFX_CXX_STANDARD',None)
                result=subprocess.run(['bash',str(script)],env=env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                entries=[json.loads(line) for line in log.read_text().splitlines()]
                clone=next(entry for entry in entries if entry[0]=='git' and 'clone' in entry)
                root=str(Path(clone[-1]).parent)
                logs.append([[token.replace(root,'BUILD_ROOT') for token in entry] for entry in entries])
            self.assertEqual(logs[0],logs[1],builder.name)

    @unittest.skipUnless(shutil.which('ruby'), 'Ruby YAML required')
    def test_workflow_default_and_argument_forwarding(self):
        document=json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e',
            'puts JSON.generate(YAML.load_file(ARGV[0]))',str(ROOT/'.github/workflows/build-pristine.yml')],text=True))
        inputs=document.get('on',document.get('true'))['workflow_dispatch']['inputs']
        self.assertNotIn('vfx_platform_year',inputs)
        self.assertEqual(inputs['cxx_conformance']['default'],'off')
        self.assertFalse(inputs['cxx_conformance']['required'])
        self.assertEqual(inputs['cxx_conformance']['options'],['off',*[str(y) for y in range(2023,2028)]])
        step=next(s for s in document['jobs']['build']['steps'] if s.get('name')=='Build + push pristine')
        docker=self.directory/'docker'
        docker.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:])); sys.exit(27)\n')
        docker.chmod(0o755)
        for mode in ['off','2026']:
            env={**os.environ,'PATH':str(self.directory)+os.pathsep+os.environ['PATH'], 'CXX_CONFORMANCE':mode,
                 'BASE_IMAGE':'fixture','CYCLES_TAG':'fixture','CYCLES_REPO':'https://fixture/cycles',
                 'MOONRAY_TAG':'fixture','MOONRAY_REPO':'https://fixture/moonray','MOONRAY_TOOLSET':'gcc-toolset-12',
                 'WITH_CYCLES_OSL':'ON','WITH_CYCLES_OPENVDB':'ON','OPENUSD_TAG':'fixture',
                 'IMAGE_TAG':'fixture','IMAGE_VERSION':'','PRISTINE_IMAGE':'fixture'}
            result=subprocess.run(['bash','-c',step['run']],cwd=self.directory,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,27,result.stderr)
            argv=json.loads((self.directory/'build-pristine.log').read_text())
            self.assertIn('CXX_CONFORMANCE='+mode,argv)
            for key in ['cycles_repo','moonray_repo','moonray_toolset']:
                if key in inputs: self.assertIn(key.upper()+'='+env[key.upper()],argv)

    def test_docker_rejects_enabled_without_source(self):
        logical=(ROOT/'Dockerfile.pristine').read_text().replace('\\\n','')
        command=next(line[4:] for line in logical.splitlines() if line.startswith('RUN ') and 'CXX_CONFORMANCE requires' in line)
        command=command.replace('/usr/local/aswf/build-support',str(ROOT/'build-support'))
        for mode, expected in [('off',0),('2026',1),('2028',1)]:
            result=subprocess.run(['bash','-c',command],env={**os.environ,'CXX_CONFORMANCE':mode,'CYCLES_TAG':''},text=True,capture_output=True)
            self.assertEqual(result.returncode,expected,result.stderr)
            if mode=='2026': self.assertIn('requires a Cycles source build',result.stderr)

    @unittest.skipUnless(shutil.which('ruby'), 'Ruby YAML required')
    def test_workflow_rejects_enabled_without_source(self):
        document=json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e','puts JSON.generate(YAML.load_file(ARGV[0]))',str(ROOT/'.github/workflows/build-pristine.yml')],text=True))
        steps=document['jobs']['build']['steps']
        step=next(s for s in steps if s.get('name')=='Validate conformance request')
        self.assertLess(steps.index(step),next(i for i,s in enumerate(steps) if s.get('name')=='Log in to GHCR'))
        for mode, expected in [('off',0),('2026',1),('2028',1)]:
            result=subprocess.run(['bash','-e','-c',step['run']],cwd=ROOT,env={**os.environ,'CXX_CONFORMANCE':mode,'CYCLES_TAG':''},text=True,capture_output=True)
            self.assertEqual(result.returncode,expected,result.stderr)

    def test_docker_default_off_and_enabled_cleanup(self):
        logical=(ROOT/'Dockerfile.pristine').read_text().replace('\\\n','')
        commands=[line[4:] for line in logical.splitlines() if line.startswith('RUN ') and 'vfx_' in line]
        aswf=self.directory/'aswf'
        aswf.mkdir()
        shutil.copytree(ROOT/'build-support',aswf/'build-support')
        builder=aswf/'build_cycles.sh'
        builder.write_text('#!/bin/sh\n'
            'printf "%s|%s|%s" "$CXX" "$CUDA_HOST_COMPILER" "${VFX_CXX_STANDARD:-}" > "$FIXTURE_BUILD_LOG"\n'
            'exit "${FIXTURE_BUILD_FAILURE:-0}"\n')
        builder.chmod(0o755)
        for mode,failure in [('off',0),('2026',0),('off',23),('2026',23)]:
            with self.subTest(mode=mode,failure=failure):
                root=self.directory/'build-root'
                root.mkdir(exist_ok=True)
                log=self.directory/'builder.log'
                calls=self.directory/'compiler.calls'
                calls.unlink(missing_ok=True)
                env={**os.environ,'CXX_CONFORMANCE':mode,'ASWF_DTS_VERSION':'14',
                     'CYCLES_TAG':'fixture','WITH_CYCLES_OSL':'ON','WITH_CYCLES_OPENVDB':'ON',
                     'CXX':'chosen-cxx','CUDA_HOST_COMPILER':'cuda-gcc-12',
                     'VFX_TOOLSET_ROOT':str(self.toolsets),'FIXTURE_BUILD_LOG':str(log),
                     'FIXTURE_COMPILER_LOG':str(calls),'FIXTURE_BUILD_FAILURE':str(failure)}
                for command in commands:
                    command=command.replace('/usr/local/aswf',str(aswf)).replace('/opt/rh',str(self.toolsets)).replace('/opt/build-cycles',str(root))
                    result=subprocess.run(['bash','-c',command],env=env,text=True,capture_output=True)
                    if result.returncode: break
                self.assertEqual(result.returncode,failure,result.stdout+result.stderr)
                self.assertEqual(root.exists(),bool(failure))
                self.assertNotIn('compile_commands.json',logical)
                if mode=='off':
                    self.assertEqual(log.read_text(),'chosen-cxx|cuda-gcc-12|')
                    self.assertFalse(calls.exists())
                else:
                    self.assertTrue(log.read_text().endswith('|cuda-gcc-12|20'))
                shutil.rmtree(root,ignore_errors=True)

    @unittest.skipUnless(shutil.which('cmake') and shutil.which('c++'), 'local CMake compiler required')
    def test_requested_standard_builds_without_database(self):
        for standard in [17,20]:
            source=self.directory/str(standard)
            source.mkdir()
            (source/'main.cpp').write_text('int main() { return 0; }\n')
            (source/'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\nadd_executable(fixture main.cpp)\n')
            build=source/'build'
            result=subprocess.run(['cmake','-S',str(source),'-B',str(build),f'-DCMAKE_CXX_STANDARD={standard}','-DCMAKE_CXX_STANDARD_REQUIRED=ON'],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run(['cmake','--build',str(build)],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertFalse((build/'compile_commands.json').exists())

if __name__ == '__main__':
    unittest.main()
