#!/usr/bin/env python3
"""Build local pristine and runnable images from a JSON profile."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def build(path):
    profile = json.loads(path.read_text())
    year = profile['year']
    if type(year) is not int:
        raise ValueError('year must be an integer')
    base = profile['base_image']
    if not isinstance(base, str) or not re.fullmatch(
            r'[^\s]+@sha256:[0-9a-f]{64}', base):
        raise ValueError('base_image must include a sha256 digest')
    first = base.split('/')[0]
    if not ('/' in base and ('.' in first or ':' in first or first == 'localhost')):
        base = 'docker.io/' + (base if '/' in base else 'library/' + base)
    suffix = f'{year}-{uuid.uuid4().hex[:12]}'
    pristine = f'docker.io/library/usd-render-benchmark-pristine:{suffix}'
    runnable = f'docker.io/library/usd-render-benchmark-runnable:{suffix}'
    revision = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    subprocess.run([
        'docker', 'build', '--file', 'Dockerfile.pristine',
        '--build-arg', f'BASE_IMAGE={base}',
        '--build-arg', f'IMAGE_VERSION={year}',
        '--build-arg', f'BUILD_CREATED={datetime.now(timezone.utc).isoformat()}',
        '--build-arg', f'RECIPE_REVISION={revision}',
        '--build-arg', f'BASE_NAME={base}',
        '--build-arg', f'BASE_DIGEST={base.split("@")[1]}',
        '--tag', pristine, '.'], cwd=ROOT, check=True)
    subprocess.run([
        'docker', 'build', '--file', 'Dockerfile.runnable',
        '--build-arg', f'PRISTINE_IMAGE={pristine}',
        '--build-arg', f'BASE_NAME={pristine}',
        '--tag', runnable, '.'], cwd=ROOT, check=True)
    print(f'Pristine: {pristine}\nRunnable: {runnable}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=Path, help='Profile JSON file')
    args = parser.parse_args()
    try:
        build(args.profile)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
