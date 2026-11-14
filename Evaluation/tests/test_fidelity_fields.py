import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("fidelity_validator", Path(__file__).parents[1] / "validate_cases.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class FidelityFieldsTests(unittest.TestCase):
    def check(self, fields):
        v.errors.clear()
        v.validate_fidelity("SYNTHETIC", fields)
        return list(v.errors)

    def test_optional_and_valid(self):
        self.assertEqual(self.check({}), [])
        self.assertEqual(self.check(dict(reference="確認して", endsOpen=True,
            dictionarySurfaces=["Example"], corrections=[dict(old="前", new="後")], tags=["endsOpen"])), [])

    def test_invalid_types_and_values(self):
        for fields in [dict(reference=" "), dict(reference=1), dict(endsOpen=1),
                       dict(tags=["unknown"]), dict(tags="long"), dict(dictionarySurfaces=[1]),
                       dict(corrections={}), dict(corrections=[dict(old="前", new="")]),
                       dict(reference="確認。", endsOpen=True), dict(reference="done.", endsOpen=True)]:
            with self.subTest(fields=fields):
                self.assertTrue(self.check(fields))
