import json
from pathlib import Path
import unittest

class MoonRayInputs(unittest.TestCase):
    def test_only_toolset_changes(self):
        root = Path(__file__).parent
        original = {p['id']: p for p in json.loads((root / 'annual-inputs.json').read_text())['pairs']}
        selected = json.loads((root / 'moonray-gcc14-inputs.json').read_text())
        self.assertEqual([p['id'] for p in selected['pairs']], ['moonray-2026', 'moonray-2027'])
        for p in selected['pairs']:
            expected = original[p['id']]
            expected['build_args']['MOONRAY_TOOLSET'] = 'gcc-toolset-14'
            self.assertEqual(p, expected)
        self.assertEqual(selected['build_timeout_seconds'], 2700)
