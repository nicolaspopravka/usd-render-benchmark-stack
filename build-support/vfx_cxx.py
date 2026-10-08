#!/usr/bin/env python3
"""Check the optional annual host C++ profile, not inherited components."""

import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


def resolve(executable, directory=None):
    if '/' in executable:
        path = Path(executable)
        if not path.is_absolute():
            path = Path(directory or '.') / path
    else:
        found = shutil.which(executable)
        if not found:
            raise ValueError(f'compiler not found: {executable}')
        path = Path(found)
    return str(path.resolve())


def compiler_settings(args):
    compiler = resolve(args.compiler)
    version = subprocess.check_output([compiler, '-dumpfullversion'], text=True).strip()
    macros = subprocess.check_output(
        [compiler, '-dM', '-E', '-x', 'c++', '-'], input='#include <string>\n', text=True)
    if '__clang__' in macros or not re.search(r'^#define __GNUC__ ', macros, re.M):
        raise ValueError('the annual host compiler must be GCC')
    if not version.startswith(args.release + '.') and version != args.release:
        raise ValueError(f'expected GCC {args.release}.x, found {version}')
    if not re.search(r'^#define _GLIBCXX_USE_CXX11_ABI 1$', macros, re.M):
        raise ValueError('expected the new libstdc++ ABI (_GLIBCXX_USE_CXX11_ABI=1)')
    language = re.search(r'^#define __cplusplus ([0-9]+)L?$', macros, re.M)
    if not language:
        raise ValueError('compiler default C++ standard cannot be determined')
    default = {199711: 98, 201103: 11, 201402: 14, 201703: 17, 202002: 20, 202302: 23}
    return {'compiler': compiler, 'version': version, 'libstdcxx_cxx11_abi': 1,
            'default_standard': default.get(int(language[1]))}


def expand_response_files(tokens, directory, seen=None):
    result = []
    seen = set() if seen is None else seen
    for token in tokens:
        if not token.startswith('@'):
            result.append(token)
            continue
        path = (Path(directory) / token[1:]).resolve()
        if path in seen:
            raise ValueError(f'recursive response file: {path}')
        result.extend(expand_response_files(shlex.split(path.read_text()), directory, seen | {path}))
    return result


def verify_commands(args, compiler_profile):
    database = json.loads(Path(args.database).read_text())
    expected = resolve(args.compiler)
    standards = {dialect + suffix: year
                 for dialect in ['c++', 'gnu++']
                 for suffix, year in [('17', 17), ('1z', 17), ('20', 20), ('2a', 20)]}
    checked = 0
    skipped = 0
    for entry in database:
        # CUDA/ISPC and pure C are separate from the host C++ SDK configuration.
        if Path(entry['file']).suffix not in {'.cpp', '.cc', '.cxx', '.C', '.c++'}:
            skipped += 1
            continue
        tokens = entry.get('arguments') or shlex.split(entry['command'])
        tokens = expand_response_files(tokens, entry['directory'])
        # CMake permits compiler launchers; only accept known transparent ones.
        while tokens and Path(tokens[0]).name in {'ccache', 'sccache'}:
            tokens = tokens[1:]
        try:
            if not tokens or resolve(tokens[0], entry['directory']) != expected:
                raise ValueError('host compiler differs from the selected annual compiler')
            selected = None
            abi = '1'
            for i, token in enumerate(tokens):
                if token == '-ansi':
                    selected = 'c++98'
                if token.startswith('-std='):
                    selected = token.split('=', 1)[1]
                definition = token[2:] if token.startswith('-D') else ''
                if token == '-D' and i + 1 < len(tokens):
                    definition = tokens[i + 1]
                if definition == '_GLIBCXX_USE_CXX11_ABI':
                    abi = '1'
                if definition.startswith('_GLIBCXX_USE_CXX11_ABI='):
                    abi = definition.split('=', 1)[1]
                if token.startswith('-U_GLIBCXX_USE_CXX11_ABI') or (
                    token == '-U' and i + 1 < len(tokens) and tokens[i + 1] == '_GLIBCXX_USE_CXX11_ABI'
                ):
                    abi = None
            effective = compiler_profile['default_standard'] if selected is None else standards.get(selected)
            if effective != args.standard:
                found = selected or f"compiler default C++{compiler_profile['default_standard']}"
                raise ValueError(f'expected C++{args.standard}, found {found}')
            if abi != '1':
                raise ValueError(f'command selects libstdc++ ABI {abi}, expected 1')
        except ValueError as error:
            raise ValueError(f'{entry["file"]}: {error}\ncommand: {shlex.join(tokens)}') from error
        checked += 1
    if not checked:
        raise ValueError('no host C++ compile commands available; settings cannot be verified')
    return {'compiler': expected, 'standard': args.standard, 'host_cxx_commands': checked,
            'other_commands': skipped, 'libstdcxx_cxx11_abi': 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    for operation in ['compiler', 'profile']:
        command = commands.add_parser(operation)
        command.add_argument('--compiler', required=True)
        command.add_argument('--release', required=True)
        if operation == 'profile':
            command.add_argument('--database', required=True)
            command.add_argument('--standard', type=int, choices=[17, 20], required=True)
    args = parser.parse_args()
    try:
        result = compiler_settings(args)
        if args.operation == 'profile':
            result.update(verify_commands(args, result))
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
