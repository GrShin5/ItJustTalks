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
                                    env={**os.environ, 'PATH': tmp + ':' + os.environ['PATH'], 'SECURITY_MARKER': str(marker), 'ITJUSTTALKS_LANG': 'ja'}, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertEqual(result.stdout, '=== 既存証明書の信頼修復 ===\n「キーチェーンアクセス.app」で「ログイン」の "ItJustTalks Dev" を検索し、ダブルクリック。\n「信頼」を展開し「コード署名」だけを「常に信頼」に変更し、macOSの認証を完了してください。\n既存証明書がある場合は新しく作成しないでください。crtファイルは不要です。\n\n=== 証明書がない場合の手動作成手順 ===\n1. 「キーチェーンアクセス.app」を開く\n2. メニューバー: キーチェーンアクセス → 証明書アシスタント → 証明書を作成...\n3. 名前: "ItJustTalks Dev"\n4. identity種類: 自己署名ルート\n5. 証明書の種類: コード署名\n6. 「デフォルトを上書き」にチェックし、鍵ペア用途を「このアイテムのデフォルトを常に使用」から\n   コード署名を確実に含める設定にして作成\n7. 作成後、「ログイン」キーチェーンに保存されていることを確認\n8. ターミナルで `security find-identity -v -p codesigning` を実行し、\n   "ItJustTalks Dev" が一覧に出ることを確認する\n\n作成後、このスクリプトを再実行すればハッシュが表示されます。\n'.encode())
            self.assertEqual(result.stderr, b'')
            result = subprocess.run(['bash', str(ROOT / 'scripts/make_signing_cert.sh'), '--interactive-help'],
                                    env={**os.environ, 'PATH': tmp + ':' + os.environ['PATH'],
                                         'SECURITY_MARKER': str(marker), 'ITJUSTTALKS_LANG': 'en'}, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertIn(b'Repair trust for an existing certificate', result.stdout)
            self.assertIn(b'Manually create a certificate', result.stdout)
            self.assertFalse(any(ord(c) > 127 and c != '→' for c in result.stdout.decode()))
            self.assertEqual(result.stderr, b'')


    def run_make_app_identity_check(self, identities, lang):
        # Copy only make_app.sh and its language helper (no preflight), fake 'security'.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'scripts/lib').mkdir(parents=True)
            (root / 'scripts/make_app.sh').write_text((ROOT / 'scripts/make_app.sh').read_text())
            (root / 'scripts/lib/ui_lang.sh').write_text((ROOT / 'scripts/lib/ui_lang.sh').read_text())
            bindir = root / 'bin'
            bindir.mkdir()
            fake = bindir / 'security'
            fake.write_text('#!/bin/sh\nprintf "%s" "$FAKE_IDENTITIES"\n')
            fake.chmod(0o755)
            env = {**os.environ, 'PATH': str(bindir) + ':' + os.environ['PATH'],
                   'FAKE_IDENTITIES': identities, 'ITJUSTTALKS_LANG': lang}
            return subprocess.run(['bash', str(root / 'scripts/make_app.sh'), 'release'],
                                  env=env, capture_output=True, text=True)

    def test_make_app_identity_errors_keep_full_messages(self):
        two = ''.join(f'  {i}) {c * 40} "ItJustTalks Dev"\n' for i, c in ((1, 'A'), (2, 'B')))
        cases = [('', 'ja', 'エラー: 安定したコード署名アイデンティティ "ItJustTalks Dev" が見つかりません。', 'bash scripts/make_signing_cert.sh --interactive-help'),
                 ('', 'en', 'Error: A stable code-signing identity named "ItJustTalks Dev" was not found.', 'bash scripts/make_signing_cert.sh --interactive-help'),
                 (two, 'ja', 'エラー: "ItJustTalks Dev" と同名の有効なコード署名アイデンティティが複数あります。', 'もう一度実行してください。'),
                 (two, 'en', 'Error: More than one valid code-signing identity is named "ItJustTalks Dev".', 'then retry.')]
        for identities, lang, first, last in cases:
            result = self.run_make_app_identity_check(identities, lang)
            self.assertEqual(result.returncode, 2)
            self.assertIn(first, result.stderr)
            self.assertIn(last, result.stderr)

if __name__ == '__main__':
    unittest.main()
