#!/usr/bin/env python3
"""Offline regression tests. Never invokes Swift, a model, or keychain APIs."""
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


manual = load('manual', 'scripts/build_manual.py')
validator = load('validator', 'Evaluation/validate_cases.py')


class ManualTests(unittest.TestCase):
    def test_anchor_followed_immediately_by_heading(self):
        blocks = manual.parse_blocks(['<a id="chapter-one"></a>', '## Chapter one', '', '[chapter](#chapter-one)'])
        toc = []
        manual.assign_heading_ids(blocks, {}, toc)
        page = manual.render_blocks(blocks, {'missing_images': []})
        self.assertEqual(len(toc), 1)
        self.assertEqual(manual.check_anchors(page), [])
        self.assertIn('<h2', page)
        self.assertEqual(page.count('id="chapter-one"'), 1)
        # Only the exact safe anchor grammar is accepted, never arbitrary HTML.
        blocks = manual.parse_blocks(['<a id="x" onclick="unsafe()"></a>'])
        self.assertEqual(blocks[0]['type'], 'para')

    def test_current_manuals_have_complete_toc_and_no_broken_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(manual, 'DIST_DIR', Path(tmp)):
                self.assertEqual(manual.main(), 0)
                for lang in manual.LANGS:
                    source = (manual.DOCS_DIR / lang['src']).read_text()
                    expected = sum(1 for line in source.splitlines() if line.startswith('## '))
                    blocks = manual.parse_blocks(source.splitlines()[1:])
                    toc = []
                    manual.assign_heading_ids(blocks, {}, toc)
                    self.assertEqual(len(toc), expected)
                    self.assertGreater(expected, 10)
                    self.assertEqual(manual.check_anchors((Path(tmp) / lang['out']).read_text()), [])

    def test_broken_links_fail_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for lang in manual.LANGS:
                (root / lang['src']).write_text('# Title\n\n## Chapter\n\n[missing](#absent)\n')
            with mock.patch.object(manual, 'DOCS_DIR', root), mock.patch.object(manual, 'DIST_DIR', root / 'out'):
                self.assertEqual(manual.main(), 1)
                self.assertFalse((root / 'out').exists())


class EvaluationTests(unittest.TestCase):
    def test_all_profiles(self):
        for profile in ('', '--accuracy', '--holdout', '--holdout2', '--holdout3'):
            result = subprocess.run(['python3', '-I', str(ROOT / 'Evaluation/validate_cases.py')] + ([profile] if profile else []), capture_output=True)
            self.assertEqual(result.returncode, 0, profile)

    def test_readme_counts_match_data(self):
        readme = (ROOT / 'Evaluation/README.md').read_text()
        total = 0
        for path in (ROOT / 'Evaluation/cases').glob('*.jsonl'):
            count = len(path.read_text().splitlines())
            total += count
            self.assertRegex(readme, re.escape('cases/' + path.name) + r'\s+' + str(count) + r'\b')
        self.assertIn('The default set has %d cases' % total, readme)

    def assert_accuracy_schema_contract(self, script):
        with tempfile.TemporaryDirectory() as tmp:
            rows = [{
                'id': 'AC-%03d' % number, 'category': 'cleanup', 'lang': 'en',
                'purpose': 'Synthetic schema fixture', 'critical': False,
                'input': {'transcript': 'Synthetic schema fixture number %03d.' % number,
                          'customInstruction': None, 'dictionary': [], 'outputLanguage': 'auto', 'handsFree': False},
                'expect': {'mustContain': ['Synthetic'], 'mustNotContain': [], 'language': 'en',
                           'noAnswer': False, 'correction': None},
            } for number in range(1, 31)]
            path = Path(tmp) / 'cleanup.jsonl'
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            command = ['python3', '-I', str(script), '--accuracy', '--dir', tmp]
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0)
            rows[0]['input']['handsFree'] = 'invalid'
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'AC-001: handsFree must be bool', result.stdout)
            self.assertIn(b'FAIL: 1 problem(s)', result.stdout)
            self.assertNotIn(b'cross-set duplicate input', result.stdout)

    def test_accuracy_schema_errors_still_fail(self):
        self.assert_accuracy_schema_contract(ROOT / 'Evaluation/validate_cases.py')

    def test_accuracy_schema_contract_detects_removed_type_check(self):
        source = (ROOT / 'Evaluation/validate_cases.py').read_text()
        check = '    if not isinstance(i["handsFree"], bool):\n        err(cid, "handsFree must be bool")\n'
        self.assertEqual(source.count(check), 1)
        with tempfile.TemporaryDirectory() as tmp:
            mutant = Path(tmp) / 'validate_cases.py'
            mutant.write_text(source.replace(check, ''))
            with self.assertRaisesRegex(AssertionError, '0 != 1'):
                self.assert_accuracy_schema_contract(mutant)

    def test_cross_set_duplicates_ignore_expectation_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            directories = [Path(tmp) / name for name in ('a', 'b')]
            for number, directory in enumerate(directories):
                directory.mkdir()
                row = {'id': str(number), 'input': {'instruction': 'synthetic', 'target': None, 'targetSource': None}, 'expect': {'kind': str(number)}}
                (directory / 'routing.jsonl').write_text(json.dumps(row) + '\n')
            self.assertEqual(validator.duplicate_inputs([str(p) for p in directories]), [('0', '1')])


class ScriptTests(unittest.TestCase):
    def test_signing_help_precedes_keychain_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'security'
            marker = Path(tmp) / 'called'
            fake.write_text('#!/bin/sh\ntouch "$SECURITY_MARKER"\nexit 1\n')
            fake.chmod(0o755)
            result = subprocess.run(['bash', str(ROOT / 'scripts/make_signing_cert.sh'), '--interactive-help'],
                                    env={**os.environ, 'PATH': tmp + ':' + os.environ['PATH'], 'SECURITY_MARKER': str(marker)}, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertIn('既存証明書の信頼修復'.encode(), result.stdout)


if __name__ == '__main__':
    unittest.main()
