import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('suite', Path(__file__).resolve().parents[2] / 'scripts/dev/afm_eval_suite.py')
suite = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(suite)


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, values):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(v) + '\n' for v in values))

    def row(self, run=1, passed=True, status='complete', checks=None):
        return dict(id='SYN', category='cleanup', run=run,
                    judge=dict(pass_=passed), validator=dict(status=status)) | {
                        'judge': {'pass': passed, 'failedChecks': checks or []}}

    def test_grid_repeats_only_critical_and_rejects_duplicate_cases(self):
        path = self.root / 'cleanup.jsonl'
        self.write(path, [dict(id='A', critical=True), dict(id='B')])
        self.assertEqual(suite.expected_keys(self.root, 'cleanup', 3), {
            ('cleanup', 'A', 1), ('cleanup', 'A', 2), ('cleanup', 'A', 3), ('cleanup', 'B', 1)})
        self.write(path, [dict(id='A'), dict(id='A')])
        with self.assertRaises(ValueError):
            suite.expected_keys(self.root, 'cleanup', 1)

    def test_verification_fails_on_missing_extra_duplicate_output(self):
        expected = {('cleanup', 'SYN', 1)}
        self.write(self.root / 'records.jsonl', [self.row()])
        for values in ([], [self.row(), self.row()], [self.row(run=2)]):
            self.write(self.root / 'outputs.jsonl', values)
            with self.assertRaises(ValueError):
                suite.verify(self.root, expected)
        self.write(self.root / 'outputs.jsonl', [self.row()])
        self.assertEqual(suite.verify(self.root, expected), 1)
        self.write(self.root / 'records.jsonl', [self.row(passed=False) | {'outcome': 'failure'}])
        self.write(self.root / 'outputs.jsonl', [])
        self.assertEqual(suite.verify(self.root, expected), 1)

    def compare(self, before, after):
        base, new = self.root / 'base', self.root / 'new'
        self.write(base / 'records.jsonl', before)
        self.write(new / 'records.jsonl', after)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = suite.compare(types.SimpleNamespace(base=base, new=new))
        return code, json.loads(output.getvalue())

    def test_comparison_keeps_runs_missing_duplicates_and_adverse_transitions(self):
        code, report = self.compare([self.row(), self.row(run=2)], [self.row(status='failed'), self.row(status='failed')])
        self.assertEqual(code, 1)
        self.assertEqual(report['missing'][0][-1], 2)
        self.assertTrue(report['newDuplicates'])
        self.assertTrue(report['validatorTransitions'][0]['adverse'])

    def test_unsafe_promotion_to_complete_is_adverse_when_judge_fails(self):
        code, report = self.compare([self.row(passed=False, status='needsReview')],
                                    [self.row(passed=False, status='complete')])
        self.assertEqual(code, 1)
        self.assertTrue(report['validatorTransitions'][0]['adverse'])
        self.assertEqual(self.compare([self.row(status='needsReview')], [self.row()])[0], 0)

    def test_failed_to_failed_added_checks_are_regressions(self):
        code, report = self.compare([self.row(passed=False, checks=['a'])], [self.row(passed=False, checks=['a', 'b'])])
        self.assertEqual(code, 1)
        self.assertEqual(report['scoringRegressions'][0]['addedChecks'], ['b'])
        self.assertEqual(self.compare([self.row()], [self.row()])[0], 0)

    def test_run_is_fail_closed_and_never_reads_holdout4_by_default(self):
        repo, out = self.root / 'repo', self.root / 'out'
        for name, category in suite.SUITES:
            self.write(repo / 'Evaluation' / name / (category + '.jsonl'), [dict(id=name + category)])
        # Deliberately malformed held-out data: a default run must never parse it.
        self.write(repo / 'Evaluation/holdout4/cleanup.jsonl', [dict(no_id=True)])
        args = types.SimpleNamespace(repo=repo, out=out, binary=self.root / 'fake', repeat=1,
                                     include_holdout4=False, app_version='0.1.0', fake=True,
                                     baseline_product_revision='936edcd', build_revision='a' * 40)
        with patch.object(suite.subprocess, 'check_output', return_value='a' * 40), \
             patch.object(suite.subprocess, 'run', return_value=types.SimpleNamespace(returncode=7)) as process, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(ValueError):
                suite.run(args)
            self.assertEqual(process.call_count, 1)
            self.assertNotIn('EVAL_DONE', output.getvalue())
        args.out = self.root / 'opted-in'
        args.include_holdout4 = True
        with patch.object(suite.subprocess, 'run') as process:
            with self.assertRaises(KeyError):
                suite.run(args)
            process.assert_not_called()

    def test_complete_default_and_e2e_suite_run_and_zero_exit_incomplete_stop(self):
        repo = self.root / 'repo'
        for name, category in suite.SUITES:
            self.write(repo / 'Evaluation' / name / (category + '.jsonl'), [dict(id=name + category)])
        args = types.SimpleNamespace(repo=repo, out=self.root / 'complete', binary=self.root / 'fake', repeat=1,
                                     include_holdout4=False, include_generation_e2e=True,
                                     app_version='0.1.0', fake=True, baseline_product_revision='936edcd', build_revision='a' * 40)
        def complete(command, **kwargs):
            category = command[command.index('--category') + 1]
            destination = Path(command[command.index('--out') + 1])
            case_dir = Path(command[command.index('--cases') + 1])
            values = [dict(category=category, id=r['id'], run=1) for r in suite.rows(case_dir / (category + '.jsonl'))]
            if category == 'long':
                # An expected/recorded model failure must not stop the remaining suites.
                failed = [r | {'outcome': 'failed', 'failureCode': 'syntheticTimeout',
                               'judge': {'pass': False, 'failedChecks': ['failure']}} for r in values]
                self.write(destination / 'records.jsonl', failed)
                self.write(destination / 'outputs.jsonl', [])
            else:
                self.write(destination / 'records.jsonl', values)
                self.write(destination / 'outputs.jsonl', values)
            return types.SimpleNamespace(returncode=0)
        with patch.object(suite.subprocess, 'check_output', return_value='a' * 40), \
             patch.object(suite.subprocess, 'run', side_effect=complete) as process, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(suite.run(args), 0)
            self.assertEqual(process.call_count, 13)
            self.assertIn('EVAL_DONE', output.getvalue())
            self.assertTrue((args.out / 'cases-generation-e2e').is_dir())
        args.out = self.root / 'incomplete'
        with patch.object(suite.subprocess, 'check_output', return_value='a' * 40), \
             patch.object(suite.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as process:
            with self.assertRaises(FileNotFoundError):
                suite.run(args)
            self.assertEqual(process.call_count, 1)

    def test_missing_required_suite_stops_before_execution(self):
        args = types.SimpleNamespace(repo=self.root / 'repo', out=self.root / 'out', repeat=1, include_holdout4=False)
        with patch.object(suite.subprocess, 'run') as process:
            with self.assertRaises(FileNotFoundError):
                suite.run(args)
            process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
