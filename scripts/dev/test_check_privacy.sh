#!/bin/bash
# Offline synthetic self-test; never runs Swift or product executables.
set -euo pipefail
[[ "$#" -eq 0 ]] || { echo "Usage: $0" >&2; exit 2; }
CHECKER="$(cd "$(dirname "$0")" && pwd)/check_privacy.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/itjusttalks-privacy.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
python3 - "$CHECKER" "$FIXTURE_ROOT" <<'PY'
import hashlib
import pathlib
import re
import subprocess
import sys

checker, temp = sys.argv[1], pathlib.Path(sys.argv[2])
secret = 'FIXTURE_SECRET_BODY_NEVER_ECHO_7249'
cases = 0

def run(files=None, tag=None, allow='', identifier=0, args=None, expected=None):
    global cases
    cases += 1
    tree = temp / str(cases)
    (tree / 'Sources').mkdir(parents=True)
    (tree / 'scripts/dev').mkdir(parents=True)
    (tree / 'scripts/dev/privacy_allowlist.txt').write_text(allow)
    (tree / 'scripts/check_identifiers.sh').write_text(
        '#!/bin/bash\nset -euo pipefail\necho "identifier fixture: inspected"\nexit ' + str(identifier) + '\n')
    for name, content in (files or {}).items():
        path = tree / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    result = subprocess.run(['bash', checker] + (args if args is not None else ['--root', str(tree)]),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    # Do not print a failed result either: a regression might expose the marker.
    assert secret not in result.stdout, f'case {cases}: body disclosure'
    status = expected if expected is not None else int(tag is not None)
    assert result.returncode == status, f'case {cases}: wrong exit status {result.returncode}'
    hits = re.findall(r'^(.+?):(\d+): \[([A-Z_]+)\] (.+)$', result.stdout, re.M)
    if status != 2:
        assert 'privacy check: violations:' in result.stdout, f'case {cases}: no summary'
        assert 'identifier fixture: inspected' in result.stdout, f'case {cases}: identifier output missing'
        if tag:
            assert any(h[2] == tag for h in hits), f'case {cases}: missing {tag}'
            assert all(h[2] == tag for h in hits), f'case {cases}: unexpected check'
        else:
            assert not hits, f'case {cases}: false positive'
    return result.stdout

def swift(body, tag=None, **kwargs):
    return run({'Sources/App/Fixture.swift': body + '\n// ' + secret}, tag, **kwargs)

for body in (
    'let model = PrivateCloudComputeLanguageModel()',
    'let executor: LanguageModelExecutor',
    'let command = "fm serve"',
    'func f(model: any LanguageModel) {}',
    'func f(model: some LanguageModel) {}',
    'struct Box<T: LanguageModel> {}',
    'struct Box<T, U\n : LanguageModel> {}',
):
    swift(body, 'CLOUD_AI')
for body in ('URLSession.shared', 'import Network', 'NWConnection()', 'NWListener()',
             'NWPathMonitor()', 'CFStreamCreatePairWithSocket()', 'Socket()',
             'URL(string: "http://example.invalid")', 'let x = "https://example.invalid"',
             'URL(string: "http-prefix")',
             'let x = #"http://example.invalid"#'):
    swift(body, 'NETWORK')
for body in ('Process()', 'Process(\n)', 'NSTask()', 'posix_spawn()',
             'system("local")', 'popen("local", "r")', 'Darwin.system("local")'):
    swift(body, 'SUBPROCESS')
for body in ('SFSpeechRecognizer(locale: locale)', 'let x: SFSpeechRecognizer',
             'SFSpeechRecognizer.supportedLocales()', 'SFSpeechAudioBufferRecognitionRequest()',
             'SFSpeechURLRecognitionRequest(url: url)', 'recognitionTask(with: request)'):
    swift(body, 'SERVER_STT')
for body in ('let x = ".codex"', 'let x = "codex app-server"',
             'struct CodexAppServer {}', 'func resolveCodex() {}', 'let executable = "/bin/codex"'):
    swift(body, 'CODEX')
run({'Sources/ItJustTalks/Codex/Empty.swift': ''}, 'CODEX')
run({'Tests/Fixture.swift': 'struct Codex {}\nlet text = "https://example.invalid"'})
for body in ('print("' + secret + ' \\(text)")',
             'AppLog.shared.warn("\\(transcript)")', 'NSLog("\\(selectedText)")',
             'os_log("\\(clipboardContent)")', 'logger.info("\\(response)")',
             'AppLog.anything(\n "\\(dictionaryEntry)"\n)',
             'print("\\(String(describing: output))")',
             'print("\\(text.count) \\(body)")',
             'print(#"\\#(prompt)"#)', 'print("""\n\\(raw)\n""")',
             'print("\\(answer.prefix(10))")', 'print("\\(text.count + body)")'):
    swift(body, 'LOG_HYGIENE')
for path in ('Sources/ItJustTalks/Support/RegressionTestSuite.swift',
             'Sources/ItJustTalks/Support/AsyncRegressionTests.swift',
             'Sources/ItJustTalks/App.swift'):
    run({path: 'if mode == "--test-example" { print("\\(body)") }'}, 'LOG_HYGIENE')
for body in ('// PrivateCloudComputeLanguageModel\n/// any LanguageModel',
             '/* URLSession /* Process() */ SFSpeechRecognizer */',
             'let x = "URLSession Process() PrivateCloudComputeLanguageModel"',
             'print("\\(text.count) \\(transcript.isEmpty) \\(body.utf16.count)")',
             'SFSpeechRecognizer.authorizationStatus()',
             'SFSpeechRecognizer.requestAuthorization { status in }',
             'let status: SFSpeechRecognizerAuthorizationStatus',
             'Text("sample").font(.system(size: 12))',
             'print("ordinary diagnostic")', 'let x = "person@noreply.example.invalid"'):
    swift(body)
swift('let x = Process()', allow='SUBPROCESS|Sources/App/Fixture.swift|let x = Process()|safe synthetic fixture\n')
# All three allowlist selectors must match independently.
for allow in ('NETWORK|Sources/App/Fixture.swift|Process()|wrong check\n',
              'SUBPROCESS|Sources/App/Other.swift|Process()|wrong path\n',
              'SUBPROCESS|Sources/App/Fixture.swift|NSTask()|wrong substring\n'):
    swift('Process()', allow=allow, expected=2)
# W6: every dynamic argument is checked, even when no sensitive name occurs.
for sink in ('print', 'debugPrint', 'dump', 'NSLog', 'os_log', 'AppLog.shared.info',
             'logger.info', 'logger.debug', 'logger.error', 'logger.notice',
             'logger.warning', 'logger.fault', 'logger.log', 'logger.critical', 'logger.trace'):
    swift(sink + '(unknownDiagnostic)', 'LOG_HYGIENE')
    swift(sink + '("fixed", unknownDiagnostic)', 'LOG_HYGIENE')
for body in ('Logger().info(body)', 'logger?.error(body)', 'logger!.log(body)'):
    swift(body, 'LOG_HYGIENE')
for name in ('result', 'partial', 'message', 'value', 'string', 'error', 'error.localizedDescription'):
    swift('print("\\(' + name + ')")', 'LOG_HYGIENE')
for body in ('fputs(body, stderr)', 'fputs("fixed", stream)',
             'FileHandle.standardOutput.write(data)',
             'FileHandle.standardError .write(contentsOf: data)',
             'print(String(format: "%@", body))',
             'print("\\(String(format: \"%@\", value))")',
             'print(String(format: "%@", flag ? "fixed" : body))',
             'print("\\(error.localizedDescription.count)")',
             'print("\\(String(describing: type(of: output)))")',
             'print("fixed" + body)', 'print(String(format: dynamicFormat, number))',
             'print(String(format: "%s", pointer))',
             'print(#"\\#(message)"#)',
             'print("""\n\\(value)\n""")'):
    swift(body, 'LOG_HYGIENE')
for body in ('print("\\(AppLog.safeDescription(error))")',
             'AppLog.shared.error(AppLog.safeDescription(error))',
             'print(text.count, text.isEmpty, text.utf16.count)',
             'print(String(format: "%d %f %.3f", n, elapsed, duration))',
             'print("\\(String(format: \"%.2f\", elapsed))")',
             'print(String(format: "%@", "fixed"))',
             'print(String(format: "%@", flag ? "yes" : "no"))',
             'print("fixed", separator: ",", terminator: "\\n")',
             'print("fixed" + " literal")',
             'print(#"\\#(text.count)"#)',
             'print(#"fixed raw literal"#)', 'print("""\nfixed\n""")',
             'case .error(let message): break', 'return .error(message)'):
    swift(body)
swift('print("\\(responseState) \\(outputStatus.rawValue) \\(stopReason.rawValue)")', 'LOG_HYGIENE')
for suffix in ('State', 'Status', 'Reason', 'Kind', 'Mode', 'Phase', 'Code'):
    swift('let current' + suffix + ' = transcript; print(current' + suffix + ')', 'LOG_HYGIENE')
# Complete call and occurrence count are part of every log approval.
call = 'print(\n correlationID,\n body\n)'
digest = hashlib.sha256(call.encode()).hexdigest()
approval = f'LOG_HYGIENE|Sources/App/Fixture.swift|{digest}|1|synthetic approved sink\n'
swift(call, allow=approval)
swift(call + '\n' + call, allow=approval, expected=2)
swift(call + '\nprint(\n correlationID,\n transcript\n)', 'LOG_HYGIENE', allow=approval)
swift('let correlationID = body', allow=approval, expected=2)
fixed_digest = hashlib.sha256(b'print("fixed")').hexdigest()
swift('print("fixed")', allow=f'LOG_HYGIENE|Sources/App/Fixture.swift|{fixed_digest}|1|unused\n', expected=2)
for body in ('NewCloudLanguageModel()', 'FutureLanguageModel.default', 'extension LanguageModel {}', 'let x = LanguageModel.self',
             'LanguageModelSession(model: unknown)', 'LanguageModelSession(model: .default)'):
    swift(body, 'CLOUD_AI')
for body in ('SystemLanguageModel.default', 'LanguageModelSession(model: SystemLanguageModel.default)',
             'func model() -> SystemLanguageModel { SystemLanguageModel.default }; LanguageModelSession(model: model())'):
    swift(body)
for body in ('URLRequest(url: url)', 'NSURLConnection()', 'CFSocketCreate()', 'CFHTTPMessageCreateRequest()',
             'socket(AF_INET, SOCK_STREAM, 0)', 'Darwin.connect(fd, addr, size)', 'getaddrinfo(host, nil, nil, nil)',
             'import WebKit', 'import CloudKit', 'import MultipeerConnectivity',
             'WKWebView()', 'NetService()', 'NSUbiquitousKeyValueStore.default'):
    swift(body, 'NETWORK')
for key in ('NSAllowsArbitraryLoads', 'NSAppTransportSecurity', 'NSBonjourServices'):
    plist = '<plist><dict><key>' + key + '</key><true/></dict></plist>'
    for path in ('Config/Info.plist', 'Sources/App/Info.plist', 'Sources/App/Other.plist'):
        run({path: plist}, 'NETWORK')
    for path in ('scripts/build.sh', 'scripts/dev/generated.sh'):
        run({path: "cat <<'PLIST'\n" + plist + '\nPLIST\n'}, 'NETWORK')
for body in ('Process.run(url: url, arguments: [])', 'Process.init()', 'NSAppleScript(source: script)',
             'NSUserAppleScriptTask(url: url)', 'execv(path, argv)', 'fork()'):
    swift(body, 'SUBPROCESS')
for body in ('let codexStatus = 1', 'let CODEXMode = 1', 'let coDeXValue = 1'):
    swift(body, 'CODEX')
run({'Tests/Fixture.swift': 'let codexStatus = 1'})
# Full trimmed line, not substring; report stale entry line without its text.
swift('  let x = Process()  ', allow='SUBPROCESS|Sources/App/Fixture.swift|let x = Process()|synthetic local process\n')
output = swift('let x = Process()', expected=2,
               allow='# comment\nSUBPROCESS|Sources/App/Fixture.swift|Process()|stale substring\n')
assert 'privacy_allowlist.txt:2: stale' in output
output = run(expected=2, allow='NETWORK|Sources/App/Missing.swift|URLSession.shared|removed code\n')
assert 'privacy_allowlist.txt:1: stale' in output
# A live line for the wrong tag/path cannot suppress a violation.
run({'Sources/App/Fixture.swift': 'Process()'}, expected=2,
    allow='NETWORK|Sources/App/Fixture.swift|Process()|wrong tag\n')
run({'Sources/App/Fixture.swift': 'Process()', 'Sources/App/Other.swift': '// approved'}, expected=2,
    allow='SUBPROCESS|Sources/App/Other.swift|// approved|wrong path\n')
for body in ('let x = "/Users/synthetic/home"', 'let x = "person@example.invalid"',
             '// /Users/synthetic/home'):
    swift(body, 'PUBLIC')
run({'Config/Info.plist': '<plist><string>/Users/synthetic/home</string></plist>'}, 'PUBLIC')
for key in ('com.apple.security.network.client', 'com.apple.security.network.server',
            'com.apple.private-cloud-compute', 'example.pcc.enabled', 'example.other'):
    run({'Config/App.entitlements': '<?xml version="1.0"?><plist version="1.0"><dict><key>' + key + '</key><true/></dict></plist>'}, 'ENTITLEMENT')
run({'scripts/sign.sh': 'codesign --sign - \\\n --entitlements "$DYNAMIC" app\n'}, 'ENTITLEMENT')
run({'Config/App.entitlements': '<plist><dict/></plist>'})
run({'Config/App.entitlements': 'malformed'}, expected=2)
run(identifier=1, tag='IDENTIFIERS')
run(identifier=2, expected=2)
run(allow='malformed', expected=2)
run(args=['--unknown'], expected=2)
run(args=['--root'], expected=2)
run(args=['--root', str(temp / 'missing')], expected=2)
print(f'privacy self-test: {cases} cases PASS')
print('privacy self-test: body marker absent; exits, tags, exclusions and allowlist verified')
PY
