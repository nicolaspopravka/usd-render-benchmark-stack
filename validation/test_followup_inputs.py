import json
from pathlib import Path
import unittest

class FollowupInputs(unittest.TestCase):
    def test_only_recipe_changes_for_import_experiments(self):
        root = Path(__file__).parent
        original = {p['id']:p for p in json.loads((root/'annual-inputs.json').read_text())['pairs']}
        for delegate, commit in [('cycles','8743aa53315c1061d0eb2765633755d834ac0916'), ('embree','3775fa76b25abf69a2b680084dda36cba428c56b')]:
            pairs = json.loads((root/(delegate+'-import-inputs.json')).read_text())['pairs']
            self.assertEqual([p['year'] for p in pairs], [2023,2024,2025])
            for p in pairs:
                expected = original[p['id']]
                expected['recipe']['commit'] = commit
                self.assertEqual(p, expected)

    def test_focused_tbb_rerun_keeps_annual_inputs(self):
        root = Path(__file__).parent
        original = next(p for p in json.loads((root/'annual-inputs.json').read_text())['pairs'] if p['id']=='embree-2024')
        original['recipe']['commit'] = '54897e8f0b9481fbd22f96fdc819ef0ac966808d'
        self.assertEqual(json.loads((root/'embree-tbb-import-inputs.json').read_text())['pairs'], [original])
