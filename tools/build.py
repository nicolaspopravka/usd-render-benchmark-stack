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


def publish(tag):
    subprocess.run(['docker', 'push', tag], check=True)
    references = json.loads(subprocess.check_output(
        ['docker', 'image', 'inspect', '--format', '{{json .RepoDigests}}', tag], text=True))
    repository = tag.rsplit(':', 1)[0]
    pinned = next(ref for ref in references if ref.startswith(repository + '@'))
    manifest = json.loads(subprocess.check_output(
        ['docker', 'buildx', 'imagetools', 'inspect', tag,
         '--format', '{{json .Manifest}}'], text=True))
    if pinned.split('@')[1] != manifest['digest']:
        raise ValueError('Published tag does not match the pushed digest')
    return pinned


def build(path, push=False):
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
    pristine = f'ghcr.io/nicolaspopravka/usd-render-benchmark-stack:{suffix}'
    runnable = f'ghcr.io/nicolaspopravka/usd-render-benchmark:{suffix}'
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
    if push:
        pristine = publish(pristine)
    subprocess.run([
        'docker', 'build', '--file', 'Dockerfile.runnable',
        '--build-arg', f'PRISTINE_IMAGE={pristine}',
        '--build-arg', f'BASE_NAME={pristine}',
        '--build-arg', f'BASE_DIGEST={pristine.split("@")[1] if push else ""}',
        '--tag', runnable, '.'], cwd=ROOT, check=True)
    if push:
        runnable = publish(runnable)
    print(f'Pristine: {pristine}\nRunnable: {runnable}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=Path, help='Profile JSON file')
    parser.add_argument('--push', action='store_true', help='Publish to GHCR')
    args = parser.parse_args()
    try:
        build(args.profile, args.push)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
