#!/usr/bin/env python3
"""Exercise profile constraints using generated fixtures, never sealed cases."""
import contextlib
import importlib.util
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / 'Evaluation' / 'validate_cases.py'
TASKS = ('proofread_rewrite', 'translate', 'transform', 'summarize', 'extract',
         'explain_analyze', 'answer_question', 'compose_reply')


def fixture(stem, prefix, count):
    rows = []
    for n in range(1, count + 1):
        lang = 'ja' if n % 10 < 6 else ('en' if n % 10 < 8 else 'mixed')
        row = {'id': f'{prefix}-{n:03}', 'category': stem, 'lang': lang,
               'purpose': 'synthetic fixture', 'critical': False}
        if stem == 'cleanup':
            row['input'] = {'transcript': f'old{n} new{n}', 'customInstruction': 'style',
                'dictionary': [{'preferred': 'term', 'readings': ['reading'], 'memo': None}],
                'outputLanguage': 'ja', 'handsFree': True}
            row['expect'] = {'mustContain': [f'new{n}'], 'mustNotContain': [f'old{n}'],
                'language': 'ja', 'noAnswer': False, 'correction': {'old': f'old{n}', 'new': f'new{n}'}}
        elif stem == 'routing':
            task = TASKS[(n - 1) % len(TASKS)]
            answer = task in ('explain_analyze', 'answer_question', 'compose_reply')
            row['input'] = {'instruction': f'fixture {n}', 'target': None if n > 18 else f'target {n}',
                            'targetSource': None if n > 18 else 'selection'}
            if n > 18:
                task, kind, replacement = 'insufficient_target', 'clarification', None
            else:
                kind, replacement = ('answer', False) if answer else ('content', True)
            row['expect'] = {'outputIntent': 'automatic', 'taskType': task,
                'isReplacementArtifact': replacement, 'kind': kind, 'injection': False}
        elif stem == 'generation':
            task = TASKS[(n - 1) % len(TASKS)]
            row['input'] = {'instruction': f'fixture {n}', 'target': f'target {n}',
                            'taskType': task, 'outputLanguage': 'ja'}
            row['expect'] = {'mustContain': ['term'], 'mustNotContain': [],
                             'language': 'en' if task == 'translate' and n % 16 == 2 else 'ja',
                             'maxLengthRatio': None}
        else:
            row['input'] = {'draft': f'fixture {n}', 'dictionary': [],
                            'mode': 'cleanup' if n % 2 else 'aiCommand'}
            row['expect'] = {'maxItems': 5, 'maxGraphemes': 500, 'mustPreserve': ['term'],
                             'flagsPermissionItems': False}
        rows.append(row)
    return rows

class Holdout4ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temp.name) / 'fixture'
        self.directory.mkdir()
        self.validator = pathlib.Path(self.temp.name) / 'validate_cases.py'
        shutil.copy2(VALIDATOR, self.validator)
        self.addCleanup(self.temp.cleanup)
        for stem, prefix, count in (('cleanup', 'H4C', 60), ('routing', 'H4R', 20),
                                    ('generation', 'H4G', 30), ('optimization', 'H4O', 10)):
            self.write(stem, fixture(stem, prefix, count))

    def write(self, name, rows):
        (self.directory / (name + '.jsonl')).write_text(
            ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows), encoding='utf-8')

    def run_profile(self):
        return subprocess.run([sys.executable, '-I', str(self.validator), '--dir', str(self.directory), '--holdout4'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode

    def mutate(self, name, operation):
        path = self.directory / (name + '.jsonl')
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        operation(rows)
        self.write(name, rows)

    def test_valid(self):
        self.assertEqual(self.run_profile(), 0)

    def test_count(self):
        self.mutate('cleanup', lambda rows: rows.pop())
        self.assertNotEqual(self.run_profile(), 0)

    def test_prefix(self):
        self.mutate('routing', lambda rows: rows[0].update(id='BAD-001'))
        self.assertNotEqual(self.run_profile(), 0)

    def test_language_coverage(self):
        self.mutate('optimization', lambda rows: [row.update(lang='ja') for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_dictionary_coverage(self):
        self.mutate('cleanup', lambda rows: [row['input'].update(dictionary=[]) for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_handsfree_coverage(self):
        self.mutate('cleanup', lambda rows: [row['input'].update(handsFree=False) for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_custom_instruction_coverage(self):
        self.mutate('cleanup', lambda rows: [row['input'].update(customInstruction=None) for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_blank_custom_instruction_coverage(self):
        self.mutate('cleanup', lambda rows: [row['input'].update(customInstruction='  ') for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_generation_tasks(self):
        self.mutate('generation', lambda rows: [row['input'].update(taskType='transform') for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_optimization_modes(self):
        self.mutate('optimization', lambda rows: [row['input'].update(mode='cleanup') for row in rows])
        self.assertNotEqual(self.run_profile(), 0)

    def test_other_profiles_do_not_scan_sealed_directory(self):
        spec = importlib.util.spec_from_file_location('validator', self.validator)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for option in ([], ['--accuracy'], ['--holdout'], ['--holdout2'], ['--holdout3']):
            with self.subTest(option=option), mock.patch.object(sys, 'argv', ['validator', '--dir', str(self.directory)] + option), \
                 mock.patch.object(module, 'duplicate_inputs', return_value=[]) as duplicate, \
                 contextlib.redirect_stdout(io.StringIO()):
                module.errors.clear()
                module.main()
                self.assertTrue(duplicate.called)
                self.assertNotIn(str(pathlib.Path(self.temp.name) / 'holdout4'), duplicate.call_args.args[0])

    def test_sealed_directory_requires_explicit_profile(self):
        sealed = pathlib.Path(self.temp.name) / 'holdout4'
        shutil.copytree(self.directory, sealed)
        result = subprocess.run([sys.executable, '-I', str(self.validator), '--dir', str(sealed)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
