#!/usr/bin/env python3
"""Resolve an annual profile and build two local images. No registry publication."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def resolve(year, variant):
    profile = json.loads((ROOT / 'profiles' / f'cy{year}.json').read_text())
    if profile['year'] != year:
        raise ValueError('Profile year does not match its filename')
    base = profile['base_image']
    if base is not None and not re.fullmatch(r'[^\s]+@sha256:[0-9a-f]{64}', base):
        raise ValueError('base_image must include a sha256 digest')
    if profile['repairs']:
        raise ValueError('Repair execution is not implemented yet')
    if profile['candidate_overrides']:
        raise ValueError('Candidate source overrides are not implemented yet')
    if set(profile['delegates']) != {'storm', 'embree', 'cycles', 'moonray'}:
        raise ValueError('Profile must describe all four delegates')
    for name, delegate in profile['delegates'].items():
        if not isinstance(delegate['included'], bool):
            raise ValueError(f'{name}: included must be a boolean')
        if name != 'storm' and delegate['included']:
            raise ValueError(f'{name}: builder integration is not implemented yet')
        if not delegate['included'] and not delegate.get('reason'):
            raise ValueError(f'{name}: exclusion needs a reason')
    return {**profile, 'variant': variant,
            'candidate_identical_to_released': not bool(profile['candidate_overrides']),
            'ready_to_build': base is not None}


def build(profile):
    if not profile['ready_to_build']:
        raise ValueError('Pin base_image in the annual profile before building')
    attempt = f"cy{profile['year']}-{profile['variant']}-{uuid.uuid4().hex[:12]}"
    output = ROOT / '.build' / attempt
    output.mkdir(parents=True)
    receipt = {'profile': profile, 'outputs': {}, 'status': 'building'}
    receipt['recipe_commit'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    receipt['recipe_dirty'] = bool(subprocess.check_output(
        ['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    try:
        for stage, argument in [('pristine', profile['base_image']), ('runnable', None)]:
            tag = f'usd-render-benchmark-{stage}:{attempt}'
            iid = output / f'{stage}.iid'
            parent = argument or receipt['outputs']['pristine']['image_id']
            command = ['docker', 'build', '--file', f'Dockerfile.{stage}',
                       '--build-arg', f"{'BASE_IMAGE' if stage == 'pristine' else 'PRISTINE_IMAGE'}={parent}",
                       '--tag', tag, '--iidfile', str(iid), '.']
            with (output / f'{stage}.log').open('w') as log:
                subprocess.run(command, cwd=ROOT, stdout=log,
                               stderr=subprocess.STDOUT, check=True)
            image_id = iid.read_text().strip()
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
                raise ValueError(f'{stage}: Docker returned an invalid image ID')
            receipt['outputs'][stage] = {'tag': tag, 'image_id': image_id}
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
    parser.add_argument('--year', type=int, choices=range(2023, 2028), required=True)
    parser.add_argument('--variant', choices=['released', 'candidate'], default='released')
    args = parser.parse_args()
    try:
        profile = resolve(args.year, args.variant)
        result = profile if args.command == 'resolve' else build(profile)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Error: {error}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
