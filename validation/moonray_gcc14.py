"""Enabled-only MoonRay follow-up; retain original annual inputs separately."""
import json
import os
from pathlib import Path
import sys
from build_pair import run_attempt

name, recipe, output = sys.argv[1:]
manifest = json.loads(Path(__file__).with_name('moonray-gcc14-inputs.json').read_text())
pair = next(p for p in manifest['pairs'] if p['id'] == name)
directory = Path(output)
directory.mkdir(parents=True, exist_ok=True)
for filename, value in [('inputs.json', pair), ('manifest.json', manifest)]:
    (directory / filename).write_text(json.dumps(value, indent=2) + '\n')
result = {'pair': name, 'attempts': [], 'run_id': os.getenv('GITHUB_RUN_ID'),
          'workflow_commit': os.getenv('GITHUB_SHA'), 'comparison_run': '37994841643'}
def persist(record):
    result['attempts'] = [record]
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
record = run_attempt(pair, str(pair['year']), recipe, directory,
                     manifest['build_timeout_seconds'], 'on', persist)
sys.exit(0 if record['status'] == 'build success' else 1)
