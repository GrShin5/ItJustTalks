#!/usr/bin/env python3
"""Fail-closed suite execution and comparison. Prints identifiers/codes only, never output text."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

CATEGORIES = ('cleanup', 'routing', 'generation', 'optimization', 'long')
SUITES = [('cases', c) for c in CATEGORIES] + [
    ('holdout', 'cleanup'), ('holdout', 'routing'), ('holdout2', 'cleanup'),
    ('holdout2', 'routing'), ('holdout3', 'cleanup'), ('fidelity', 'cleanup'), ('accuracy', 'cleanup')]


def rows(path):
    with path.open() as stream:
        return [json.loads(line) for line in stream if line.strip()]


def indexed(values):
    result, duplicates = {}, []
    for row in values:
        key = (row['category'], row['id'], row['run'])
        if not isinstance(key[1], str) or not isinstance(key[2], int) or isinstance(key[2], bool) or key[2] < 1:
            raise ValueError('invalid record key')
        if key in result:
            duplicates.append(key)
        result[key] = row
    return result, duplicates


def expected_keys(cases, category, repeat):
    values = rows(cases / (category + '.jsonl'))
    ids = [r['id'] for r in values]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError('empty or duplicate case ids')
    return {(category, r['id'], run) for r in values
            for run in range(1, (repeat if r.get('critical', False) else 1) + 1)}


def verify(directory, expected):
    records, duplicates = indexed(rows(directory / 'records.jsonl'))
    if duplicates or set(records) != expected:
        raise ValueError('records.jsonl: missing, extra or duplicate keys')
    outputs, duplicates = indexed(rows(directory / 'outputs.jsonl'))
    if duplicates or set(outputs) - expected:
        raise ValueError('outputs.jsonl: extra or duplicate keys')
    for key in expected - set(outputs):
        record = records[key]
        # A faithfully recorded model failure has no generated text. It remains in the fixed grid;
        # unexplained loss of a successful result is an infrastructure/collection error.
        failed_execution = (record.get('failureCode') is not None or
                            record.get('outcome') not in (None, 'ok', 'complete', 'needsReview'))
        if not failed_execution or (record.get('judge') or {}).get('pass') is not False:
            raise ValueError('outputs.jsonl: unexplained missing key')
    return len(expected)


def run(args):
    repo, out = args.repo.resolve(), args.out.resolve()
    if out == repo or repo in out.parents:
        raise ValueError('output must be outside repository')
    if out.exists():
        raise ValueError('output directory must be new')
    suites = list(SUITES)
    if args.include_holdout4:
        suites += [('holdout4', c) for c in CATEGORIES if c != 'long']
    # Preflight every expected set before invoking anything. No discovery reads holdout4 by default.
    plan = [(name, category, 'oracle', expected_keys(repo / 'Evaluation' / name, category, args.repeat))
            for name, category in suites]
    if getattr(args, 'include_generation_e2e', False):
        plan.append(('cases', 'generation', 'e2e', expected_keys(repo / 'Evaluation/cases', 'generation', args.repeat)))
    import re
    if not re.fullmatch(r'[a-fA-F0-9]{40,64}', args.build_revision):
        raise ValueError('--build-revision must be the full actual binary build commit')
    revision = args.build_revision
    tool_revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
    baseline = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', args.baseline_product_revision + '^{commit}'], text=True).strip()
    env = dict(os.environ, AFM_EVAL_SOURCE_REVISION=revision, AFM_EVAL_TOOL_REVISION=tool_revision,
               AFM_EVAL_BASELINE_PRODUCT_REVISION=baseline,
               AFM_EVAL_APP_VERSION=args.app_version, AFM_EVAL_SDK_VERSION=sdk)
    out.mkdir(parents=True)
    audit = []
    for name, category, path, expected in plan:
        suite_name = name + '-' + category + ('-e2e' if path == 'e2e' else '')
        destination = out / suite_name
        command = [str(args.binary.resolve()), '--cases', str(repo / 'Evaluation' / name),
                   '--out', str(destination), '--category', category, '--repeat', str(args.repeat)]
        if category == 'generation':
            command += ['--generation-path', path]
        if args.fake:
            command.append('--fake')
        # Retain tool logs privately; do not echo potentially producer-specific output.
        with (out / (suite_name + '.log')).open('w') as log:
            completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        entry = dict(suite=suite_name, generationPath=path if category == 'generation' else None, exitCode=completed.returncode, expected=len(expected))
        audit.append(entry)
        (out / 'suite-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
        if completed.returncode:
            raise ValueError(entry['suite'] + ': process failed')
        entry['verified'] = verify(destination, expected)
        (out / 'suite-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
        print(entry['suite'] + ': verified ' + str(len(expected)))
    print('EVAL_DONE')
    return 0


def collect(root):
    """One run directory or a suite tree; rescore.json takes precedence over old judgments."""
    result, duplicate = {}, []
    directories = {p.parent for p in root.rglob('records.jsonl')} | {p.parent for p in root.rglob('rescore.json')}
    if not directories:
        raise ValueError('no evaluation records')
    for directory in sorted(directories):
        rescore = directory / 'rescore.json'
        values = json.loads(rescore.read_text())['records'] if rescore.exists() else rows(directory / 'records.jsonl')
        records, repeated = indexed(values)
        namespace = str(directory.relative_to(root))
        duplicate.extend([(namespace, *key) for key in repeated])
        for key, value in records.items():
            result[(namespace, *key)] = value
    return result, duplicate


def compare(args):
    base, base_duplicates = collect(args.base)
    new, new_duplicates = collect(args.new)
    report = dict(missing=sorted(set(base) - set(new)), added=sorted(set(new) - set(base)),
                  baseDuplicates=base_duplicates, newDuplicates=new_duplicates,
                  regressions=[], validatorTransitions=[], scoringRegressions=[], pathMismatches=[])
    rank = {'complete': 0, 'needsReview': 1, 'failed': 2, 'unavailable': 3}
    def judge(row):
        return row.get('judge') or row
    for key in sorted(set(base) & set(new)):
        before, after = base[key], new[key]
        b, n = judge(before), judge(after)
        if b.get('pass') is True and n.get('pass') is not True:
            report['regressions'].append(key)
        checks = sorted(set(n.get('failedChecks', [])) - set(b.get('failedChecks', [])))
        if checks:
            report['scoringRegressions'].append(dict(key=key, addedChecks=checks))
        old = (before.get('validator') or {}).get('status', 'unavailable')
        now = (after.get('validator') or {}).get('status', 'unavailable')
        if old != now:
            report['validatorTransitions'].append(dict(key=key, before=old, after=now,
                                                       adverse=(rank.get(now, 3) > rank.get(old, 3) or
                                                                (now == 'complete' and old != 'complete' and n.get('pass') is not True))))
        if before.get('generationPath', 'oracle') != after.get('generationPath', 'oracle'):
            report['pathMismatches'].append(key)
    adverse = any(report[k] for k in ('missing', 'added', 'baseDuplicates', 'newDuplicates', 'regressions',
                                     'scoringRegressions', 'pathMismatches'))
    adverse |= any(r['adverse'] for r in report['validatorTransitions'])
    print(json.dumps(report, indent=2, ensure_ascii=True))
    return int(adverse)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    runner = sub.add_parser('run')
    runner.add_argument('--repo', type=Path, required=True)
    runner.add_argument('--out', type=Path, required=True)
    runner.add_argument('--binary', type=Path, required=True)
    runner.add_argument('--build-revision', required=True, help='full source commit actually used to build --binary')
    runner.add_argument('--app-version', default='0.1.0')
    runner.add_argument('--baseline-product-revision', required=True, help='product commit used as the comparison baseline')
    runner.add_argument('--repeat', type=int, default=1)
    runner.add_argument('--include-holdout4', action='store_true')
    runner.add_argument('--include-generation-e2e', action='store_true')
    runner.add_argument('--fake', action='store_true')
    comparator = sub.add_parser('compare')
    comparator.add_argument('base', type=Path)
    comparator.add_argument('new', type=Path)
    args = parser.parse_args()
    if getattr(args, 'repeat', 1) < 1:
        parser.error('--repeat must be positive')
    try:
        return run(args) if args.command == 'run' else compare(args)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        print('evaluation contract failed; inspect local audit and inputs', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
