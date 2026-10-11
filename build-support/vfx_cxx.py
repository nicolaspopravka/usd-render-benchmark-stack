#!/usr/bin/env python3
"""Check the optional annual host C++ profile, not inherited components."""

import argparse
import json
from pathlib import Path
import re
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
    return {'compiler': compiler, 'version': version, 'libstdcxx_cxx11_abi': 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['compiler'])
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--release', required=True)
    args = parser.parse_args()
    try:
        result = compiler_settings(args)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
