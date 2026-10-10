#!/usr/bin/env python3
"""Build-only evidence for frozen annual off/on comparisons."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

MANIFEST = Path(os.getenv('CXX_INPUT_MANIFEST', str(Path(__file__).with_name('annual-inputs.json'))))


def load_pair(name):
    manifest = json.loads(MANIFEST.read_text())
    return next(p for p in manifest['pairs'] if p['id'] == name), manifest


def source_commit(source):
    ref = source['ref']
    output = subprocess.check_output(
        ['git', 'ls-remote', source['repository'], f'refs/heads/{ref}',
         f'refs/tags/{ref}', f'refs/tags/{ref}^{{}}'], text=True, timeout=90)
    refs = dict(line.split()[::-1] for line in output.splitlines())
    return refs.get(f'refs/tags/{ref}^{{}}', refs.get(f'refs/tags/{ref}', refs.get(f'refs/heads/{ref}')))


def command(pair, mode, context):
    arguments = {'BASE_IMAGE': pair['base_image'], **pair['build_args'], 'CXX_CONFORMANCE': mode}
    args = ['docker', 'buildx', 'build', '--platform', 'linux/amd64', '--progress=plain',
            '--provenance=false', '--output', 'type=cacheonly', '--file', str(Path(context) / 'Dockerfile.pristine')]
    for name, value in arguments.items():
        args.extend(['--build-arg', f'{name}={value}'])
    return args + [str(context)]


def classify(code, log, mode):
    if code == 124 or any(s in log for s in ['no space left on device', 'Cannot connect to the Docker daemon', '429 Too Many Requests', 'failed to authorize', 'TLS handshake timeout']):
        return 'infrastructure interruption'
    if any(s in log for s in ['conflicts with CY', 'ERROR: expected GCC', 'ERROR: expected the new libstdc++ ABI', 'ERROR: missing annual compiler', 'ERROR: the annual host compiler', 'ERROR: no host C++ compile commands', ': expected C++', ': command selects libstdc++ ABI', ': host compiler differs']):
        return 'compiler/profile rejection'
    if code == 0:
        if mode != 'off' and not re.search(r'"host_cxx_commands": [1-9][0-9]*', log):
            return 'missing profile evidence'
        return 'build success'
    if 'CMake Error' in log:
        return 'configure failure'
    if any(s in log for s in ['undefined reference', 'ld returned', 'cannot find -l']):
        return 'link failure'
    if any(s in log for s in ['fatal error:', 'error:', 'Error 1', 'Error 2']):
        return 'compile/build failure'
    return 'build failure (stage requires log review)'


def run_attempt(pair, mode, context, directory, limit, label, persist):
    record = {'pair': pair['id'], 'mode': mode, 'label': label,
              'recipe_commit': pair['recipe']['baseline' if label == 'baseline-off' else 'commit'],
              'command': command(pair, mode, context), 'status': 'running'}
    persist(record)
    log_path = directory / (label + '.log')
    start = time.monotonic()
    try:
        before = source_commit(pair['source'])
        record['source_commit_before'] = before
        if before != pair['source']['commit']:
            raise ValueError(f"source ref drift: expected {pair['source']['commit']}, found {before}")
        print(f"Starting {pair['id']} {label}", flush=True)
        with log_path.open('w') as log:
            process = subprocess.Popen(record['command'], stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        log = log_path.read_text(errors='replace')
        record.update(exit_status=code, log=log_path.name, status=classify(code, log, mode))
        record['source_commit_after'] = source_commit(pair['source'])
        record['source_commit_observed_in_build_log'] = bool(re.search(r'(?<![a-f0-9])' + pair['source']['commit'] + r'(?![a-f0-9])', log))
        if record['source_commit_after'] != pair['source']['commit']:
            record['status'] = 'source ref drift'
        elif code == 0 and not record['source_commit_observed_in_build_log']:
            record['status'] = 'missing source evidence'
        print('\n'.join(log.splitlines()[-45:]), flush=True)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        record.update(status='input/infrastructure interruption', diagnostic=str(error))
        log_path.touch(exist_ok=True)
        record['log'] = log_path.name
    finally:
        record['elapsed_seconds'] = round(time.monotonic() - start, 3)
        persist(record)
    print(f"Finished {pair['id']} {label}: {record['status']}", flush=True)
    return record


def run_pair(name, recipe, baseline, output):
    pair, manifest = load_pair(name)
    directory = Path(output)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'inputs.json').write_text(json.dumps(pair, indent=2) + '\n')
    result = {'pair': pair['id'], 'attempts': [], 'run_id': os.getenv('GITHUB_RUN_ID'),
              'run_attempt': os.getenv('GITHUB_RUN_ATTEMPT'), 'workflow_commit': os.getenv('GITHUB_SHA')}
    def persist(record):
        existing = next((i for i, x in enumerate(result['attempts']) if x['label'] == record['label']), None)
        if existing is None:
            result['attempts'].append(record)
        else:
            result['attempts'][existing] = record
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    off = run_attempt(pair, 'off', recipe, directory, manifest['build_timeout_seconds'], 'off', persist)
    if off['status'] != 'build success':
        control = run_attempt(pair, 'off', baseline, directory, manifest['build_timeout_seconds'], 'baseline-off', persist)
        result['off_comparison'] = ('possible regression; compare logs' if control['status'] == 'build success'
                                    else 'both recipes failed; compare diagnostics before claiming same cause')
    on = run_attempt(pair, str(pair['year']), recipe, directory, manifest['build_timeout_seconds'], 'on', persist)
    persist(on)
    return 0 if off['status'] == on['status'] == 'build success' else 1


def report(manifest_path, directory):
    manifest = json.loads(Path(manifest_path).read_text())
    found = {}
    for path in Path(directory).rglob('result.json'):
        value = json.loads(path.read_text())
        found[value['pair']] = value
    print('# Annual host C++ build comparison\n')
    print('Build-only findings; no images published and no runtime/render acceptance. Failed steps require log review.\n')
    print('| Delegate | Year | Off | Enabled | Baseline control | Evidence |')
    print('| --- | --- | --- | --- | --- | --- |')
    for pair in manifest['pairs']:
        value = found.get(pair['id'], {})
        attempts = {r['label']: r for r in value.get('attempts', [])}
        def outcome(label):
            r = attempts.get(label)
            if not r:
                return 'Not recorded' if label != 'baseline-off' else 'Not needed / not recorded'
            return f"{r['status']} (exit {r.get('exit_status', 'not started')}, {r.get('elapsed_seconds', 0):.0f}s)"
        run = value.get('run_id', os.getenv('GITHUB_RUN_ID', ''))
        link = f'[cxx-pair-{pair["id"]}](https://github.com/nicolaspopravka/usd-render-benchmark-stack/actions/runs/{run})'
        print(f'| {pair["delegate"]} | {pair["year"]} | {outcome("off")} | {outcome("on")} | {outcome("baseline-off")} | {link} |')
    print('\nEach artifact includes frozen inputs, exact commands, elapsed time, exit status and full build logs. Prepared bases can contain other delegates; only the selected delegate is rebuilt. Compiler/profile summaries appear in enabled build logs. Source refs are checked against the frozen commit before/after each attempt; drift is an input finding, never silently repinned.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['inputs', 'run', 'report'])
    parser.add_argument('arguments', nargs='+')
    args = parser.parse_args()
    if args.operation == 'inputs':
        pair, _ = load_pair(args.arguments[0])
        for name, value in pair['recipe'].items():
            print(f'{name}={value}')
        return 0
    if args.operation == 'report':
        report(*args.arguments)
        return 0
    return run_pair(*args.arguments)


if __name__ == '__main__':
    sys.exit(main())
