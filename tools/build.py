#!/usr/bin/env python3
"""Resolve an annual profile and build two local images. No registry publication."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def resolve(path):
    profile = json.loads(path.read_text())
    if type(profile['year']) is not int or not 1000 <= profile['year'] <= 9999:
        raise ValueError('Profile year must be a four-digit integer')
    base = profile['base_image']
    if base is not None and not re.fullmatch(r'[^\s]+@sha256:[0-9a-f]{64}', base):
        raise ValueError('base_image must include a sha256 digest')
    if profile['repairs']:
        raise ValueError('Repair execution is not implemented yet')
    if set(profile['delegates']) != {'storm', 'embree', 'cycles', 'moonray'}:
        raise ValueError('Profile must describe all four delegates')
    for name, delegate in profile['delegates'].items():
        if not isinstance(delegate['included'], bool):
            raise ValueError(f'{name}: included must be a boolean')
        if name != 'storm' and delegate['included']:
            raise ValueError(f'{name}: builder integration is not implemented yet')
        if not delegate['included'] and not delegate.get('reason'):
            raise ValueError(f'{name}: exclusion needs a reason')
    return profile


def qualified_reference(reference):
    first = reference.split('/')[0]
    if '/' in reference and ('.' in first or ':' in first or first == 'localhost'):
        return reference
    return 'docker.io/' + (reference if '/' in reference else 'library/' + reference)


def verify_pristine(receipt):
    pristine = receipt['outputs']['pristine']
    actual = subprocess.check_output(
        ['docker', 'image', 'inspect', '--format', '{{.Id}}', pristine['tag']],
        text=True).strip()
    if actual != pristine['image_id']:
        raise ValueError('Local pristine tag changed during the build')


def build(profile):
    if profile['base_image'] is None:
        raise ValueError('Pin base_image in the annual profile before building')
    attempt = f"cy{profile['year']}-{uuid.uuid4().hex[:12]}"
    output = ROOT / '.build' / attempt
    output.mkdir(parents=True)
    (output / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    receipt = {'profile': 'profile.json', 'outputs': {},
               'created': datetime.now(timezone.utc).isoformat()}
    receipt['recipe_commit'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if subprocess.check_output(
            ['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        receipt['recipe_dirty'] = True
    try:
        for stage, argument in [('pristine', profile['base_image']), ('runnable', None)]:
            tag = f'docker.io/library/usd-render-benchmark-{stage}:{attempt}'
            iid = output / f'{stage}.iid'
            parent = argument or receipt['outputs']['pristine']['tag']
            if stage == 'runnable':
                verify_pristine(receipt)
            command = ['docker', 'build', '--file', f'Dockerfile.{stage}',
                       '--build-arg', f"{'BASE_IMAGE' if stage == 'pristine' else 'PRISTINE_IMAGE'}={parent}",
                       '--build-arg', f"IMAGE_VERSION={profile['year']}",
                       '--build-arg', f"BUILD_CREATED={receipt['created']}",
                       '--build-arg', f"RECIPE_REVISION={receipt['recipe_commit']}",
                       '--build-arg', f'BASE_NAME={qualified_reference(parent)}',
                       '--build-arg', f'BASE_DIGEST={parent.split("@")[-1] if stage == "pristine" else ""}',
                       '--tag', tag, '--iidfile', str(iid), '.']
            with (output / f'{stage}.log').open('w') as log:
                subprocess.run(command, cwd=ROOT, stdout=log,
                               stderr=subprocess.STDOUT, check=True)
            image_id = iid.read_text().strip()
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
                raise ValueError(f'{stage}: Docker returned an invalid image ID')
            receipt['outputs'][stage] = {'tag': tag, 'image_id': image_id}
            if stage == 'runnable':
                verify_pristine(receipt)
        receipt['status'] = 'built'
    except Exception as error:
        receipt['status'] = 'failed'
        receipt['error'] = str(error)
        raise
    finally:
        path = output / 'receipt.json'
        path.write_text(json.dumps(receipt, indent=2) + '\n')
        print(f'Receipt: {path}', file=sys.stderr)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['resolve', 'build'])
    parser.add_argument('profile', type=Path, help='Path to a profile JSON file')
    args = parser.parse_args()
    try:
        profile = resolve(args.profile)
        result = profile if args.command == 'resolve' else build(profile)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Error: {error}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
