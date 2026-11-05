#!/bin/bash
# Read-only privacy inspection of the product sources. Requires bash and python3 (standard library only).
# Usage: bash scripts/dev/check_privacy.sh [--root DIR]
# Exit: 0 = clean, 1 = violations, 2 = usage/environment error.
# This is a lexical guard, not a Swift compiler or data-flow analysis. It handles
# nested comments, ordinary/raw/multiline strings and balanced log calls. Aliases,
# assembled strings, indirect logging and shell-generated entitlements need review.
# LOG_HYGIENE checks every argument, permitting literals, count/isEmpty/utf16.count,
# numeric String(format:) and AppLog.safeDescription. %@ requires literals.
# Log approvals bind SHA-256 of the complete trimmed call and expected occurrence count.
# Other approvals bind exact source lines. Every entry must suppress a finding.
# ENTITLEMENT has no globally permitted keys; every exception must be line-specific.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$#" -ne 0 ]]; then
  [[ "$#" -eq 2 && "$1" == --root && -n "$2" ]] || { echo "Usage: $0 [--root DIR]" >&2; exit 2; }
  ROOT="$2"
fi
[[ -d "$ROOT/Sources" && -f "$ROOT/scripts/check_identifiers.sh" && -f "$ROOT/scripts/dev/privacy_allowlist.txt" ]] || {
  echo "error: root requires Sources, identifier checker and privacy allowlist" >&2; exit 2;
}
command -v python3 >/dev/null 2>&1 || { echo "error: python3 required" >&2; exit 2; }
python3 - "$ROOT" <<'PY'
import hashlib
import bisect
import collections
import pathlib
import re
import subprocess
import sys

TAGS = ('CLOUD_AI', 'NETWORK', 'SUBPROCESS', 'SERVER_STT', 'ENTITLEMENT',
        'CODEX', 'IDENTIFIERS', 'LOG_HYGIENE', 'PUBLIC')
root = pathlib.Path(sys.argv[1]).resolve()
counts = collections.Counter()
allowed = []
used = collections.Counter()
log_occurrences = collections.Counter()

def error():
    # Never echo exceptions: decoding/parser errors can include source bodies.
    print('error: unreadable input, malformed allowlist or identifier checker failure', file=sys.stderr)
    sys.exit(2)

def inspect():
    for allow_line, line in enumerate((root / 'scripts/dev/privacy_allowlist.txt').read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split('|')
        is_log = fields[0] == 'LOG_HYGIENE'
        if len(fields) != (5 if is_log else 4) or fields[0] not in TAGS or not all(fields):
            error()
        if fields[1].startswith('/') or '..' in pathlib.PurePosixPath(fields[1]).parts:
            error()
        if fields[1].startswith('Sources/ItJustTalks/Codex/'):
            error()
        if is_log:
            if not re.fullmatch(r'[a-f0-9]{64}', fields[2]) or not fields[3].isdigit() or int(fields[3]) < 1:
                error()
        else:
            target = root / fields[1]
            if not target.is_file() or fields[2] not in [x.strip() for x in target.read_text().splitlines()]:
                print(f'scripts/dev/privacy_allowlist.txt:{allow_line}: stale allowlist entry', file=sys.stderr)
                sys.exit(2)
        key = tuple(fields[:3])
        if any(tuple(entry[:3]) == key for _, entry in allowed): error()
        allowed.append((allow_line, fields))

    def scan(path):
        rel = path.relative_to(root).as_posix()
        src = path.read_text()
        lines = src.splitlines()
        starts = [0] + [m.end() for m in re.finditer('\n', src)]
        seen = set()

        def emit(tag, offset, reason):
            line = bisect.bisect_right(starts, offset)
            key = (tag, line)
            if key in seen:
                return
            seen.add(key)
            original = lines[line - 1] if line <= len(lines) else ''
            for entry_line, fields in allowed:
                if fields[0] == tag and fields[1] == rel and fields[2] == original.strip():
                    used[entry_line] += 1
                    return
            counts[tag] += 1
            print(f'{rel}:{line}: [{tag}] {reason}')

        if path.suffix == '.swift':
            # Parallel buffers preserve source offsets without printing source.
            clean, code = list(src), list(src)
            strings = []
            n = len(src)
            string_start = re.compile(r'(#{0,})("""|")')

            def blank(buf, a, b):
                for k in range(a, b):
                    if src[k] != '\n':
                        buf[k] = ' '

            def lex(i, interpolation=False):
                depth = 1
                while i < n:
                    if src.startswith('//', i):
                        end = src.find('\n', i)
                        end = n if end < 0 else end
                        blank(clean, i, end); blank(code, i, end)
                        i = end
                    elif src.startswith('/*', i):
                        a, nesting = i, 1
                        i += 2
                        while i < n and nesting:
                            if src.startswith('/*', i):
                                nesting += 1; i += 2
                            elif src.startswith('*/', i):
                                nesting -= 1; i += 2
                            else:
                                i += 1
                        blank(clean, a, i); blank(code, a, i)
                    else:
                        opening = string_start.match(src, i)
                        if opening:
                            a = i
                            hashes, quotes = opening.groups()
                            endmark = quotes + hashes
                            escape = '\\' + hashes
                            i += len(opening.group())
                            interpolations = []
                            while i < n:
                                if src.startswith(endmark, i):
                                    i += len(endmark)
                                    break
                                if src.startswith(escape + '(', i):
                                    b = i + len(escape) + 1
                                    end = lex(b, True)
                                    interpolations.append((b, end - 1))
                                    i = end
                                elif src.startswith(escape, i):
                                    i += len(escape) + 1
                                else:
                                    i += 1
                            strings.append((a, i, interpolations))
                            expressions = [(x, y, code[x:y]) for x, y in interpolations]
                            blank(code, a, i)
                            for x, y, expression in expressions:
                                code[x:y] = expression
                        elif interpolation and src[i] == '(':
                            depth += 1; i += 1
                        elif interpolation and src[i] == ')':
                            depth -= 1; i += 1
                            if depth == 0:
                                return i
                        else:
                            i += 1
                return i

            lex(0)
            clean, code = ''.join(clean), ''.join(code)
            patterns = {
                'CLOUD_AI': r'\b(?!SystemLanguageModel\b)(?:[A-Za-z_]\w*LanguageModel|LanguageModel)\b|\b(?:PrivateCloudComputeLanguageModel|LanguageModelExecutor)\b|\b(?:any|some)\s+LanguageModel\b|\b\w+\s*:\s*LanguageModel\b',
                'NETWORK': r'\b(?:URLSession|URLRequest|NSURLConnection|CFSocket\w*|CFHTTP\w*|NWConnection|NWListener|NWPathMonitor|CFStreamCreatePairWithSocket|WKWebView|NetService|NSUbiquitousKeyValueStore)\b|\bimport\s+(?:Network|WebKit|CloudKit|MultipeerConnectivity)\b|\b(?:Socket|socket|connect|getaddrinfo)\s*\(',
                'SUBPROCESS': r'\bProcess\s*(?:\(\s*\)|\.\s*(?:run|init)\s*\()|\b(?:NSTask|NSAppleScript|NSUserAppleScriptTask|execv\w*|posix_spawn\w*)\b|\bfork\s*\(|(?<![\w.])(?:system|popen)\s*\(|\bDarwin\s*\.\s*(?:system|popen)\s*\(',
                'SERVER_STT': r'\bSFSpeechRecognizer\b(?!\s*\.\s*(?:authorizationStatus\s*\(|requestAuthorization\b))|\b(?:SFSpeechAudioBufferRecognitionRequest|SFSpeechURLRecognitionRequest)\b|\brecognitionTask\s*\(',
                'CODEX': r'(?i)\b\w*codex\w*\b',
            }
            for tag, pattern in patterns.items():
                for match in re.finditer(pattern, code):
                    emit(tag, match.start(), 'forbidden product API or identifier')
            for match in re.finditer(r'\bLanguageModelSession\s*\(\s*model\s*:', code):
                argument = code[match.end():].lstrip()
                typed_names = re.findall(r'\b(?:let|var)\s+(\w+)\s*:\s*SystemLanguageModel\b', code)
                typed_functions = re.findall(r'\bfunc\s+(\w+)\s*\([^{}]*?\)\s*->\s*SystemLanguageModel\s*\{', code)
                typed = any(re.match(re.escape(name) + r'\b' + (r'\s*\(' if name in typed_functions else ''), argument)
                            for name in typed_names + typed_functions)
                if not typed and not re.match(r'SystemLanguageModel\s*\.\s*default\b|SystemLanguageModel\s*\(', argument):
                    emit('CLOUD_AI', match.start(), 'session model requires SystemLanguageModel')
            if '/Codex/' in '/' + rel:
                emit('CODEX', 0, 'legacy executable integration directory')
            for a, b, _ in strings:
                literal = clean[a:b]
                if re.search(r'\bURL\s*\(\s*string\s*:\s*$', clean[:a]) and re.match(r'#*"http', literal):
                    emit('NETWORK', a, 'HTTP URL construction in product code')
                for tag, pattern in (
                    ('CLOUD_AI', r'\bfm\s+serve\b'),
                    ('NETWORK', r'"https?://'),
                    ('CODEX', r'\.codex\b|\bcodex\s+app-server\b|(?:^|[/"\s])codex(?:["\s]|$)'),
                ):
                    if re.search(pattern, literal):
                        emit(tag, a, 'forbidden product string reference')

            sensitive = re.compile(r'text|transcript|selection|selected|clipboard|pasteboard|prompt|instruction|dictionary|entry|entries|reading|preferred|content|body|output|answer|response|utterance|source|raw|result|partial|message|value|string', re.I)
            # Strings (including their interpolations) are atomic when splitting
            # call arguments. clean retains literals; code masks literal text.
            literals = {a: (b, xs) for a, b, xs in strings}

            def trim(a, b):
                while a < b and clean[a].isspace(): a += 1
                while b > a and clean[b - 1].isspace(): b -= 1
                return a, b

            def arguments(a, b, separator=','):
                local = list(code[a:b])
                for x, y, _ in strings:
                    if a <= x and y <= b: local[x-a:y-a] = ' ' * (y-x)
                start, depth, parts = a, 0, []
                for j in range(a, b):
                    c = local[j-a]
                    if c in '([{': depth += 1
                    elif c in ')]}': depth -= 1
                    elif c == separator and depth == 0:
                        parts.append(trim(start, j)); start = j + 1
                if clean[start:b].strip(): parts.append(trim(start, b))
                return parts

            def closing(a):
                depth = 1
                for j in range(a, n):
                    if code[j] == '(': depth += 1
                    elif code[j] == ')':
                        depth -= 1
                        if depth == 0: return j
                return n

            def literal_text(a, b):
                a, b = trim(a, b)
                pieces = []
                while a < b:
                    if a not in literals: return None
                    end, xs = literals[a]
                    if end > b or xs: return None
                    pieces.append(clean[a:end])
                    a, _ = trim(end, b)
                    if a == b: break
                    if clean[a] != '+': return None
                    a, _ = trim(a + 1, b)
                    if a == b: return None
                return ''.join(pieces) if pieces else None

            def pure_literal(a, b):
                a, b = trim(a, b)
                return a in literals and literals[a][0] == b and not literals[a][1]

            failures = []

            def safe_expr(a, b):
                a, b = trim(a, b)
                before = len(failures)
                result = safe_value(a, b)
                if not result and len(failures) == before:
                    # Pin an approval to meaningful content rather than a generic
                    # multiline wrapper such as Data( or String(.
                    meaningful = next((x for x, y, _ in sorted(strings) if a <= x < b), a)
                    if clean[a:meaningful].strip() in ('Data(', 'String('):
                        if clean[meaningful:meaningful+3] == '"""':
                            meaningful = clean.find('\n', meaningful) + 1
                            while meaningful < b and clean[meaningful].isspace(): meaningful += 1
                        failures.append(meaningful)
                    else: failures.append(a)
                return result

            def safe_value(a, b):
                a, b = trim(a, b)
                expr = clean[a:b]
                concatenated = arguments(a, b, '+')
                if len(concatenated) > 1:
                    return all(safe_expr(x, y) for x, y in concatenated)
                if a in literals and literals[a][0] == b:
                    return all(safe_expr(x, y) for x, y in literals[a][1])
                if re.fullmatch(r'AppLog\s*\.\s*safeDescription\s*\(.*\)', expr, re.S):
                    opening = clean.index('(', a, b)
                    return closing(opening + 1) == b - 1
                if re.search(r'\blocalizedDescription\b|\berror\b', expr): return False
                if re.fullmatch(r'[A-Za-z_][\w.]*\.(?:count|isEmpty|utf16\.count)', expr): return True
                # String(format:) allows numeric conversions, or %@ only with
                # literal/ternary-of-literal arguments. No dynamic format string.
                fmt = re.match(r'String\s*\(\s*format\s*:', expr)
                if fmt and closing(a + expr.index('(') + 1) == b - 1:
                    parts = arguments(a + fmt.end(), b - 1)
                    if not parts or literal_text(*parts[0]) is None: return False
                    fa, fb = parts[0]
                    format_text = literal_text(fa, fb)
                    specs = re.findall(r'%(?:[-+0 ]*\d*)?(?:\.\d+)?[df@]|%%', format_text)
                    if '%' in re.sub(r'%(?:[-+0 ]*\d*)?(?:\.\d+)?[df@]|%%', '', format_text): return False
                    specs = [x for x in specs if x != '%%']
                    if len(specs) != len(parts) - 1: return False
                    for spec, (x, y) in zip(specs, parts[1:]):
                        value = clean[x:y]
                        if spec.endswith('@'):
                            if pure_literal(x, y): continue
                            ternary = re.fullmatch(r'[^?:]+\?\s*(.+?)\s*:\s*(.+)', value, re.S)
                            if not ternary:
                                failures.append(x); return False
                            if not all(pure_literal(x + ternary.start(k), x + ternary.end(k)) for k in (1, 2)):
                                failures.append(x); return False
                        elif re.search(r'\blocalizedDescription\b|\berror\b', value): return False
                        # Numeric printf conversions cannot print body strings.
                    return True
                return False

            log = r'\b(?:AppLog(?:\s*\.\s*\w+)+|print|debugPrint|dump|NSLog|os_log|fputs)\s*\(|\b(?!case\b|return\b)[A-Za-z_]\w*[!?]?\s*\.\s*(?:info|debug|error|notice|warning|fault|critical|trace|log|warn)\s*\(|(?<=\))\s*\.\s*(?:info|debug|error|notice|warning|fault|critical|trace|log|warn)\s*\(|\bFileHandle\s*\.\s*(?:standardOutput|standardError)\s*\.\s*write\s*\('
            for call in re.finditer(log, code):
                # safeDescription is a sanitizer, not a log sink.
                if re.search(r'AppLog\s*\.\s*(?:safeDescription|shared\s*\.\s*flush)', call.group()): continue
                end = closing(call.end())
                digest = hashlib.sha256(src[call.start():end + 1].strip().encode()).hexdigest()
                log_occurrences[(rel, digest)] += 1
                approved = next(((line, fields) for line, fields in allowed
                                 if fields[:3] == ['LOG_HYGIENE', rel, digest]), None)
                parts = arguments(call.end(), end)
                unsafe = False
                for a, b in parts:
                    label = re.match(r'[A-Za-z_]\w*\s*:\s*', clean[a:b])
                    if label: a += label.end()
                    failures.clear()
                    if not safe_expr(a, b):
                        reason = 'log argument may expose body data' if sensitive.search(clean[a:b]) else 'log argument requires body-safe literal or explicit approval'
                        unsafe = True
                        if not approved: emit('LOG_HYGIENE', failures[0], reason)
                if unsafe and approved: used[approved[0]] += 1
            # Publication identifiers remain sensitive even in comments.
            public_text = src
        else:
            public_text = src
            if path.suffix == '.entitlements':
                # XML keys are line-specific; binary/invalid plist is an error,
                # not a clean result. plistlib also validates the whole file.
                import plistlib
                plistlib.loads(path.read_bytes())
                for match in re.finditer(r'<key\s*>.*?</key\s*>', src, re.S):
                    emit('ENTITLEMENT', match.start(), 'entitlement key requires explicit approval')
            if path.suffix == '.sh':
                # Only codesign invocations are product inputs from scripts/*.sh.
                # Keep line offsets, including backslash-continuation arguments.
                public_lines, signing = [], False
                for line in src.splitlines(keepends=True):
                    if not line.lstrip().startswith('#') and re.search(r'\bcodesign\s', line):
                        signing = True
                    public_lines.append(line if signing else re.sub(r'[^\n]', ' ', line))
                    signing = signing and line.rstrip().endswith('\\')
                public_text = ''.join(public_lines)
                # Conservatively flag every active --entitlements argument,
                # including multiline commands/variable or generated plist paths.
                # Static entitlement files are separately inspected key by key.
                for match in re.finditer(r'(?m)^[^#\n]*?--entitlements\b', src):
                    emit('ENTITLEMENT', match.start(), 'signing entitlement argument requires explicit approval')

        if path.suffix in ('.plist', '.sh'):
            for match in re.finditer(r'<key\s*>\s*(?:NSAllowsArbitraryLoads|NSAppTransportSecurity|NSBonjourServices)\s*</key\s*>', src):
                emit('NETWORK', match.start(), 'network plist key requires explicit approval')

        for match in re.finditer(r'/Users/[^/\s"\'<>]+|[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', public_text):
            if '@' in match.group() and 'noreply' in match.group().lower():
                continue
            emit('PUBLIC', match.start(), 'home path or email address in product input')

    paths = set((root / 'Sources').rglob('*.swift'))
    # Stay within product/configuration inputs; never traverse local data, build
    # output, .git or hidden directories when finding plist/entitlement files.
    def configs(directory):
        for path in directory.iterdir():
            if path.is_symlink() or path.name.startswith('.') or path.name in ('Tests', 'local-eval', 'dist', 'build'):
                continue
            if path.is_dir():
                configs(path)
            elif path.suffix == '.entitlements' or (path.name.endswith('Info.plist') or (path.suffix == '.plist' and 'Sources' in path.relative_to(root).parts)):
                paths.add(path)
    configs(root)
    paths.update((root / 'scripts').rglob('*.sh'))
    for path in sorted(paths):
        if path.is_symlink():
            error()
        scan(path)

    invalid = False
    for entry_line, fields in allowed:
        if not used[entry_line]:
            print(f'scripts/dev/privacy_allowlist.txt:{entry_line}: unused allowlist entry', file=sys.stderr)
            invalid = True
        if fields[0] == 'LOG_HYGIENE' and log_occurrences[(fields[1], fields[2])] != int(fields[3]):
            print(f'scripts/dev/privacy_allowlist.txt:{entry_line}: log occurrence count mismatch', file=sys.stderr)
            invalid = True
    if invalid: sys.exit(2)

    # Preserve the established identifier check's output contract. Its checker
    # emits paths/counts only. Fixtures provide a deterministic local stub.
    sys.stdout.flush()
    result = subprocess.run(['bash', 'scripts/check_identifiers.sh'], cwd=root)
    if result.returncode == 1:
        counts['IDENTIFIERS'] += 1
        print('scripts/check_identifiers.sh:1: [IDENTIFIERS] identifier inspection failed')
    elif result.returncode != 0:
        error()
    print('privacy check: ' + ' '.join(f'{tag}={counts[tag]}' for tag in TAGS))
    print(f'privacy check: violations: {sum(counts.values())}')
    return int(bool(sum(counts.values())))

try:
    sys.exit(inspect())
except (OSError, UnicodeError, ValueError):
    error()
PY
