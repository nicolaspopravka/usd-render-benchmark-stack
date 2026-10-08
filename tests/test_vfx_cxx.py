"""Local fixtures only: no renderer downloads, images, dispatch or publication."""
import argparse
import importlib.util
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
spec = importlib.util.spec_from_file_location('vfx_cxx', CHECKER)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


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

    def entry(self, flags, source='fixture.cpp', compiler=None):
        return {'directory': str(self.directory), 'file': source,
                'arguments': [str(compiler or self.compiler), *flags, '-c', source]}

    def verify(self, entries, standard=20, default=17):
        database = self.directory / 'compile_commands.json'
        database.write_text(json.dumps(entries))
        args = argparse.Namespace(database=str(database), compiler=str(self.compiler), standard=standard)
        return checker.verify_commands(args, {'default_standard': default})

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
                'vfx_cxx_check /missing || exit; printf "%s|%s|%s|%s" "$CC" "$CXX" "$CUDA_HOST_COMPILER" "${VFX_CXX_STANDARD:-}"', **env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'chosen-c|chosen-cxx|cuda-gcc-12|')
            self.assertFalse((self.directory / 'calls').exists())

    def test_invalid_modes(self):
        for mode in ['', '2022', '2028', '2026.3', 'true', '2026; exit 0']:
            result = self.bash('source "$1"; vfx_select_year', CXX_CONFORMANCE=mode)
            # Empty Docker input follows the omitted/default-off behavior.
            self.assertEqual(result.returncode == 0, mode == '', result.stderr)

    def test_enabled_conflicting_toolset_fails_before_activation(self):
        result = self.bash('source "$1"; vfx_cxx_environment gcc-toolset-12',
                          CXX_CONFORMANCE='2026', VFX_TOOLSET_ROOT='/missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('conflicts with CY2026', result.stderr)
        self.assertNotIn('missing annual', result.stderr)

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

    def test_explicit_standard_and_gnu_equivalents(self):
        for standard in [17, 20]:
            for dialect in ['c++', 'gnu++']:
                result = self.verify([self.entry([f'-std={dialect}{standard}'])], standard)
                self.assertEqual(result['standard'], standard)

    def test_implicit_standard_requires_matching_probed_default(self):
        self.assertEqual(self.verify([self.entry([])], 17)['host_cxx_commands'], 1)
        for flags in [[], ['-ansi']]:
            with self.assertRaisesRegex(ValueError, r'expected C\+\+20'):
                self.verify([self.entry(flags)], 20)

    def test_final_standard_and_abi_overrides(self):
        for flags in [['-std=c++17'], ['-std=c++20', '-std=c++17'], ['-std=c++23'],
                      ['-std=c++20', '-D_GLIBCXX_USE_CXX11_ABI=0'],
                      ['-std=c++20', '-D', '_GLIBCXX_USE_CXX11_ABI=0'],
                      ['-std=c++20', '-U_GLIBCXX_USE_CXX11_ABI']]:
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                self.verify([self.entry(flags)])
        self.verify([self.entry(['-std=c++17', '-std=gnu++20', '-D_GLIBCXX_USE_CXX11_ABI=0', '-D_GLIBCXX_USE_CXX11_ABI=1'])])

    def test_compiler_mismatch(self):
        with self.assertRaisesRegex(ValueError, 'host compiler differs'):
            self.verify([self.entry(['-std=c++20'], compiler='/another/g++')])

    def test_cuda_c_and_ispc_are_separate(self):
        entries = [self.entry([], 'kernel.cu', 'nvcc'), self.entry([], 'fixture.c', 'cc'),
                   self.entry([], 'fixture.ispc', 'ispc'), self.entry(['-std=c++20'])]
        self.assertEqual(self.verify(entries)['other_commands'], 3)

    def test_no_host_commands_fails(self):
        with self.assertRaisesRegex(ValueError, r'no host C\+\+'):
            self.verify([self.entry([], 'kernel.cu', 'nvcc')])

    def test_response_files_and_transparent_launcher(self):
        (self.directory / 'flags.rsp').write_text('-std=gnu++20')
        entry = self.entry(['@flags.rsp'])
        entry['arguments'].insert(0, 'ccache')
        self.verify([entry])
        (self.directory / 'flags.rsp').write_text('-std=c++17')
        with self.assertRaises(ValueError): self.verify([entry])
        (self.directory / 'flags.rsp').write_text('@flags.rsp')
        with self.assertRaisesRegex(ValueError, 'recursive'): self.verify([entry])
        with self.assertRaises(OSError): self.verify([self.entry(['@missing.rsp'])])

    @unittest.skipUnless(shutil.which('cmake') and shutil.which('c++'), 'local CMake compiler required')
    def test_real_cmake_explicit_implicit_and_overridden_settings(self):
        for mode, override in [('2025', ''), ('2026', ''), ('2026', 'set(CMAKE_CXX_STANDARD 17)'),
                               ('2026', 'set_property(TARGET fixture PROPERTY CXX_STANDARD 17)'),
                               ('2026', 'target_compile_options(fixture PRIVATE -std=c++17)')]:
            source = self.directory / str(len(list(self.directory.iterdir())))
            source.mkdir()
            (source / 'main.cpp').write_text('int main() { return 0; }\n')
            prefix = override if override.startswith('set(') else ''
            suffix = override if not prefix else ''
            (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
                + prefix + '\nadd_executable(fixture main.cpp)\n' + suffix + '\n')
            result = self.bash('set -e; source "$1"; vfx_cxx_environment; '
                'cmake -S "$FIXTURE_SOURCE" -B "$FIXTURE_SOURCE/build" -DCMAKE_CXX_STANDARD="$VFX_CXX_STANDARD" '
                '-DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; '
                'cmake --build "$FIXTURE_SOURCE/build"; vfx_cxx_check "$FIXTURE_SOURCE/build"',
                CXX_CONFORMANCE=mode, FIXTURE_SOURCE=str(source), FIXTURE_GCC_VERSION='11.2.1' if mode=='2025' else '14.2.1')
            self.assertEqual(result.returncode == 0, not override, result.stdout + result.stderr)
            self.assertTrue((source / 'build/fixture').exists())
            if override: self.assertIn('expected C++20', result.stderr)

    @unittest.skipUnless(shutil.which('cmake') and shutil.which('c++'), 'local CMake compiler required')
    def test_configure_compile_link_failures_stop_before_cleanup(self):
        for label, cmake_error, code in [('configure', 'invalid_command()', 'int main() { return 0; }'),
                                        ('compile', '', 'int main() { syntax error }'),
                                        ('link', '', 'extern void missing(); int main() { missing(); }')]:
            source = self.directory / label
            source.mkdir()
            (source / 'main.cpp').write_text(code+'\n')
            (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.21)\nproject(fixture LANGUAGES CXX)\n'
                                               'add_executable(fixture main.cpp)\n'+cmake_error+'\n')
            result = self.bash('set -e; source "$1"; vfx_cxx_environment; '
                'cmake -S "$FIXTURE_SOURCE" -B "$FIXTURE_SOURCE/build"; cmake --build "$FIXTURE_SOURCE/build"; '
                'vfx_cxx_check "$FIXTURE_SOURCE/build"; rm -rf "$FIXTURE_SOURCE/build"',
                CXX_CONFORMANCE='2026', FIXTURE_SOURCE=str(source))
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((source / 'build/CMakeCache.txt').exists())

    def test_enabled_missing_database_fails_but_off_does_not_probe(self):
        result = self.bash('set -e; source "$1"; vfx_cxx_environment; vfx_cxx_check /missing', CXX_CONFORMANCE='2026')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compile_commands.json', result.stderr)


class RecipeTests(unittest.TestCase):
    setUp = Fixtures.setUp
    tearDown = Fixtures.tearDown
    def test_default_builder_commands_match_established_recipes(self):
        base = 'feature/moonray-input' if (ROOT / 'build_cycles.sh').exists() else 'fix/embree'
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

    def test_docker_default_off_and_enabled_cleanup(self):
        logical=(ROOT/'Dockerfile.pristine').read_text().replace('\\\n','')
        commands=[line[4:] for line in logical.splitlines() if line.startswith('RUN ') and 'vfx_' in line]
        aswf=self.directory/'aswf'
        aswf.mkdir()
        support=aswf/'build-support'
        shutil.copytree(ROOT/'build-support',support)
        fixers=aswf/'moonray-fixers'
        fixers.mkdir()
        for name in ['01-gitlfs-prereqs.sh','02-openusd-cmake-exports.sh','03-ispc.sh','04-moonray-toolset.sh']:
            path=fixers/name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        for builder in ROOT.glob('build_*.sh'):
            script=aswf/builder.name
            script.write_text('#!/usr/bin/env python3\nimport os,json,pathlib,sys\n'
                'with open(os.environ["FIXTURE_BUILD_LOG"],"a") as log: log.write(json.dumps({key:os.getenv(key) for key in ["CC","CXX","CUDA_HOST_COMPILER","VFX_CXX_STANDARD"]})+"\\n")\n'
                'if os.getenv("FIXTURE_BUILD_FAILURE"): sys.exit(23)\n'
                'if os.getenv("VFX_CXX_STANDARD"):\n'
                ' build=pathlib.Path(os.environ["FIXTURE_BUILD_ROOT"])/("cycles/build" if "cycles" in __file__ else "build")\n'
                ' build.mkdir(parents=True,exist_ok=True)\n'
                ' standard=os.getenv("FIXTURE_OVERRIDE",os.environ["VFX_CXX_STANDARD"])\n'
                ' entry={"file":"fixture.cpp","directory":str(build),"arguments":[os.environ["CXX"],"-std=gnu++"+standard,"-c","fixture.cpp"]}\n'
                ' (build/"compile_commands.json").write_text(json.dumps([entry]))\n')
            python_script=script.with_suffix(".py")
            python_script.write_text(script.read_text())
            script.write_text("#!/bin/sh\nexec python3 " + shlex.quote(str(python_script)) + "\n")
            script.chmod(0o755)
        available=['cycles','moonray'] if (ROOT/'build_cycles.sh').exists() else ['embree']
        cases=[('off','',None,0),('off','gcc-toolset-12',None,0),('2026','',None,0),
               ('2026','gcc-toolset-12',None,1),('2026','', '17',1),('off','', 'build-failure',23)]
        for delegate in available:
            for mode,requested,override,expected in cases:
                if delegate!='moonray' and requested: continue
                with self.subTest(delegate=delegate,mode=mode,requested=requested,override=override):
                    root=self.directory/'build-root'
                    root.mkdir(exist_ok=True)
                    (root/'retained').touch()
                    log=self.directory/'builder.jsonl'
                    calls=self.directory/'compiler.calls'
                    for path in [log,calls]:
                        if path.exists(): path.unlink()
                    # Preserve original Docker compiler paths; only substitute fixture filesystems.
                    env={**os.environ,'CXX_CONFORMANCE':mode,'ASWF_DTS_VERSION':'14',
                         'CYCLES_TAG':'fixture' if delegate=='cycles' else '',
                         'MOONRAY_TAG':'fixture' if delegate=='moonray' else '',
                         'OPENUSD_TAG':'fixture','CYCLES_REPO':'https://fixture/cycles',
                         'MOONRAY_REPO':'https://fixture/moonray','MOONRAY_TOOLSET':requested,
                         'WITH_CYCLES_OSL':'ON','WITH_CYCLES_OPENVDB':'ON',
                         'CC':'chosen-c','CXX':'chosen-cxx','CUDA_HOST_COMPILER':'cuda-gcc-12',
                         'VFX_TOOLSET_ROOT':str(self.toolsets),'FIXTURE_BUILD_ROOT':str(root),
                         'FIXTURE_BUILD_LOG':str(log),'FIXTURE_COMPILER_LOG':str(calls)}
                    if override=='build-failure': env['FIXTURE_BUILD_FAILURE']='1'
                    elif override: env['FIXTURE_OVERRIDE']=override
                    for command in commands:
                        command=command.replace('/usr/local/aswf',str(aswf)).replace('/opt/rh',str(self.toolsets))
                        for path in ['/opt/build-cycles','/opt/build-moonray','/opt/build-hdembree']:
                            command=command.replace(path,str(root))
                        result=subprocess.run(['bash','-c',command],env=env,text=True,capture_output=True)
                        if result.returncode: break
                    self.assertEqual(result.returncode,expected,result.stdout+result.stderr)
                    if expected==0:
                        self.assertFalse(root.exists(),'outer cleanup must run on success')
                        recorded=json.loads(log.read_text().splitlines()[0])
                        if mode=='off':
                            self.assertFalse(calls.exists(),'off must not probe the compiler')
                            self.assertIsNone(recorded['VFX_CXX_STANDARD'])
                            if requested:
                                self.assertIn('gcc-toolset-12/root/usr/bin/g++',recorded['CXX'])
                                self.assertEqual(recorded['CUDA_HOST_COMPILER'],recorded['CXX'])
                            else:
                                self.assertEqual(recorded['CXX'],'chosen-cxx')
                                self.assertEqual(recorded['CUDA_HOST_COMPILER'],'cuda-gcc-12')
                    else:
                        self.assertTrue(root.exists(),'failed builds/checks must stop before cleanup')
                        if requested and mode!='off':
                            self.assertFalse(log.exists(),'conflicting profile must fail before the builder')
                    shutil.rmtree(root,ignore_errors=True)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required')
    def test_hdembree_consumer_default_and_explicit_standard(self):
        path=ROOT/'cmake/hdembree-consumer/CMakeLists.txt'
        if not path.exists(): self.skipTest('hdEmbree branch only')
        text=path.read_text()
        start=text.index('if(NOT DEFINED CMAKE_CXX_STANDARD)')
        stop=text.index('set(CMAKE_CXX_STANDARD_REQUIRED ON)',start)+len('set(CMAKE_CXX_STANDARD_REQUIRED ON)')
        script=self.directory/'default.cmake'
        script.write_text(text[start:stop]+'\nmessage(STATUS "effective=${CMAKE_CXX_STANDARD}")\n')
        for flags,standard in [([],17),(['-DCMAKE_CXX_STANDARD=20'],20)]:
            result=subprocess.run(['cmake',*flags,'-P',str(script)],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn(f'effective={standard}',result.stdout)


if __name__ == '__main__':
    unittest.main()
