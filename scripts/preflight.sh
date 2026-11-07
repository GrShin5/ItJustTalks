#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# ItJustTalksのビルド前提条件を読み取り専用で一括検査する。
set -euo pipefail
QUIET=0 INSTALL=0
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ui_lang.sh"
for arg in "$@"; do case "$arg" in --quiet) QUIET=1;; --install) INSTALL=1;; *) echo "Usage: $0 [--quiet] [--install]" >&2; echo "$(t '結論: 停止（引数）' 'RESULT: blocked (arguments)')"; exit 2;; esac; done

cd "$(dirname "$0")/.."; ROOT_DIR="$(pwd)"; source "$ROOT_DIR/scripts/lib/install_checks.sh"
RESULT_LINES=(); ACTION_ITEMS=(); OVERALL_STATUS=0; WARN_COUNT=0
record() { case "$1" in ok) RESULT_LINES+=("✅ $2");; warn) RESULT_LINES+=("⚠️ $2"); WARN_COUNT=$((WARN_COUNT + 1));; fail) RESULT_LINES+=("❌ $2"); OVERALL_STATUS=2;; esac; }
print_report() { echo "$(t "=== ItJustTalksビルド前提条件チェック ===" "=== ItJustTalks build prerequisite check ===")"; printf '%s\n' "${RESULT_LINES[@]}"; if [[ ${#ACTION_ITEMS[@]} -gt 0 ]]; then echo ""; echo "$(t "=== あなたがやること ===" "=== What you need to do ===")"; local i=1; for action in "${ACTION_ITEMS[@]}"; do echo "$i. $action"; i=$((i + 1)); done; fi; }

# macOS / CLT / Swift
macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
if [[ "$(uname -s 2>/dev/null || true)" == Darwin && "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 27 ]]; then
  record ok "$(t "macOS ${macos_version}です（27以降）" "macOS ${macos_version} (27 or later) was detected")"
else
  record fail "$(t "macOS 27以降が必要です（検出値: ${macos_version:-不明}）" "macOS 27 or later is required (detected: ${macos_version:-unknown})")"
  ACTION_ITEMS+=("$(t "システム設定の「一般」→「ソフトウェアアップデート」でmacOSを更新してください。" "Update macOS in System Settings → General → Software Update.")")
fi
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "$developer_dir" ]]; then
  case "$developer_dir" in *CommandLineTools*) developer_kind="Command Line Tools";; *) developer_kind="Xcode";; esac
  record ok "$developer_kind: $developer_dir"
else
  record fail "$(t '開発ツール（Command Line Tools）が見つかりません' 'Developer tools (Command Line Tools) were not found')"
  ACTION_ITEMS+=("$(t 'ターミナルで `xcode-select --install` を実行し、表示される画面でインストールしてください（フル版Xcodeは不要です）。' 'Run `xcode-select --install` in Terminal and install from the dialog that appears (full Xcode is not needed).')")
fi
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1 || true)"; swift_ok=0
if [[ "$swift_version" =~ ^([0-9]+)\.([0-9]+)$ ]] && { [[ ${BASH_REMATCH[1]} -gt 6 ]] || { [[ ${BASH_REMATCH[1]} -eq 6 && ${BASH_REMATCH[2]} -ge 4 ]]; }; }; then swift_ok=1; fi
if [[ $swift_ok -eq 1 ]]; then record ok "$(t "Swiftのバージョンは${swift_version}です（6.4以上）" "Swift version is ${swift_version} (6.4 or later)")"; else record fail "$(t "Swift 6.4以上が必要です（検出値: ${swift_version:-不明}）" "Swift 6.4 or later is required (detected: ${swift_version:-unknown})")"; ACTION_ITEMS+=("$(t "\`softwareupdate --list\` を確認し、Swift 6.4以降を含む更新を導入してください。" "Check \`softwareupdate --list\` and install an update that includes Swift 6.4 or later.")"); fi

# SDK and a macro-free FoundationModels compile probe precede all certificate checks.
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
sdk_major="${sdk_version%%.*}"
toolchain_advice="$(t 'ソフトウェアアップデートでCommand Line Toolsを更新してください。Xcode選択が壊れている場合は、ユーザーが開発ツールの選択を確認してください。エージェントは sudo xcode-select --reset を実行しません。' 'Update Command Line Tools via Software Update. If selected Xcode is broken, the user should choose a working developer directory; the agent must not run sudo xcode-select --reset.')"
if [[ "$sdk_major" =~ ^[0-9]+$ && "$sdk_major" -ge 27 ]]; then
  record ok "macOS SDK: $sdk_version"
else
  record fail "$(t 'macOS SDK 27以降が必要です' 'macOS SDK 27 or later is required')"
  ACTION_ITEMS+=("$toolchain_advice")
fi
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
cat >"$probe_dir/probe.swift" <<'SWIFT'
import FoundationModels
func probe(_ schema: DynamicGenerationSchema) {}
SWIFT
if xcrun --sdk macosx swiftc -typecheck "$probe_dir/probe.swift" >"$probe_dir/log" 2>&1; then
  record ok "$(t 'FoundationModelsコンパイル確認OK' 'FoundationModels compile probe OK')"
else
  record fail "$(t 'AIモジュールをコンパイルできません' 'The toolchain cannot compile the AI module')"
  ACTION_ITEMS+=("$toolchain_advice")
  ACTION_ITEMS+=("$(t '制限付きサンドボックスが原因の場合は承認済みの実行範囲で再実行してください。検証は省略しません。' 'If a restricted agent sandbox caused this failure, rerun in the approved execution scope. Do not skip verification.')")
fi
if [[ $OVERALL_STATUS -ne 0 ]]; then
  print_report
  if [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 27 ]]; then
    echo "$(t '結論: 停止（開発環境）' 'RESULT: blocked (toolchain)')"
  else
    echo "$(t '結論: 停止（macOSの版）' 'RESULT: blocked (macOS version)')"
  fi
  exit 2
fi

# Keychain has four states; inaccessible is never treated as absent.
keychain_state="$(itjusttalks_keychain_state)"; signing_exists=0
case "$keychain_state" in found) signing_exists=1; record ok "$(t "コード署名用証明書 \"ItJustTalks Dev\" が見つかりました" "The code-signing certificate \"ItJustTalks Dev\" was found")";; untrusted) record warn "$(t "証明書 \"ItJustTalks Dev\" は存在しますが、有効なコード署名アイデンティティとして信頼されていません" "The certificate \"ItJustTalks Dev\" exists but is not a valid/trusted code-signing identity")"; ACTION_ITEMS+=("$(t "コード署名だけに限った信頼設定を承認したら \`bash scripts/install.sh --allow-signing-cert\`（個別に行う場合は \`bash scripts/make_signing_cert.sh\`）を実行し、macOSの認証画面で承認してください（新しい証明書は作りません）。" "After approving code-signing-only trust, run \`bash scripts/install.sh --allow-signing-cert\` (or \`bash scripts/make_signing_cert.sh\` on its own) and approve the macOS authentication dialog (no new certificate is created).")");; absent) record warn "$(t "コード署名用証明書 \"ItJustTalks Dev\" はまだ作成されていません" "The code-signing certificate \"ItJustTalks Dev\" has not been created yet")"; ACTION_ITEMS+=("$(t "証明書の作成・ログインキーチェーンへの登録・コード署名だけに限った信頼設定を承認したら \`bash scripts/install.sh --allow-signing-cert\`（個別に行う場合は \`bash scripts/make_signing_cert.sh\`）を実行し、macOSの認証画面で承認してください。" "After approving creating the certificate, registering it in the login keychain, and code-signing-only trust, run \`bash scripts/install.sh --allow-signing-cert\` (or \`bash scripts/make_signing_cert.sh\` on its own) and approve the macOS authentication dialog.")");; duplicate) record fail "$(t '「ItJustTalks Dev」という証明書が複数あり、どれを使うか決められません' 'There is more than one certificate named "ItJustTalks Dev" and none can be chosen')"; ACTION_ITEMS+=("$(t '新しく作らずに止まりました。キーチェーンアクセスで「ItJustTalks Dev」を検索し、どれを残すか確認してください。分からない場合は削除せず、相談してください。' 'Stopped without creating another. Search for "ItJustTalks Dev" in Keychain Access and decide which one to keep. If unsure, do not delete anything; ask for help.')");; inaccessible) record fail "$(t "Keychainにアクセスできません（証明書なしとは判定しません）" "The Keychain is inaccessible (not treated as a missing certificate)")"; ACTION_ITEMS+=("$(t "ログインキーチェーンを解除して再実行してください。証明書の削除や作り直しは不要です。" "Unlock the login Keychain and retry. Do not delete or recreate the certificate.")");; esac
certificate_tool="$(itjusttalks_find_certificate_tool || true)"
if [[ -n "$certificate_tool" ]]; then
  case "${certificate_tool%%$'\t'*}" in openssl3) certificate_tool_name="OpenSSL 3";; *) certificate_tool_name="LibreSSL (macOS)";; esac
  record ok "$(t "証明書作成ツール: $certificate_tool_name (${certificate_tool#*$'\t'})" "Certificate tool: $certificate_tool_name (${certificate_tool#*$'\t'})")"
else record fail "$(t 'OpenSSL 3 / LibreSSLがありません' 'Neither OpenSSL 3 nor LibreSSL is available')"; fi

# Work location: symlink, File Provider/iCloud, and dirty clone.
if [[ -L "$ROOT_DIR" || -L "$0" ]]; then
  record fail "$(t "シンボリックリンク経由の作業場所は使えません" "A symlinked work location cannot be used")"
  ACTION_ITEMS+=("$(t "~/Developer/ItJustTalksへ新しくcloneし、symlinkを使わずに作業してください。" "Make a new clone at ~/Developer/ItJustTalks and do not use a symlink.")")
else
  record ok "$(t "作業場所はシンボリックリンクではありません" "The work location is not a symlink")"
fi
if [[ -w "$ROOT_DIR" ]]; then
  record ok "$(t "作業場所へ書き込めます" "The working location is writable")"
else
  record fail "$(t "作業場所へ書き込めません" "The working location is not writable")"
  ACTION_ITEMS+=("$(t "書込み可能な~/Developerへ新しくcloneしてください。" "Make a new clone inside the writable ~/Developer folder.")")
fi
case "$ROOT_DIR/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Library/Mobile Documents/"*|*"/Library/CloudStorage/"*)
    record fail "$(t "Desktop/Documents/iCloud/File Provider配下では作業できません" "Do not work inside Desktop, Documents, iCloud, or File Provider storage")"
    ACTION_ITEMS+=("$(t "~/Developer/ItJustTalksへ新しくcloneしてください。既存フォルダは移動・再利用しないでください。" "Make a new clone at ~/Developer/ItJustTalks. Do not move or reuse the existing folder.")")
    ;;
esac
provider=0; check="$ROOT_DIR"; while [[ "$check" != / ]]; do attrs="$(xattr "$check" 2>/dev/null || true)"; [[ "$attrs" == *com.apple.file-provider-domain-id* || "$attrs" == *com.apple.fileprovider* ]] && { provider=1; break; }; check="$(dirname "$check")"; done
if [[ $provider -eq 0 ]]; then record ok "$(t "リポジトリのパスはiCloud/File Provider配下ではありません" "The repository is outside iCloud/File Provider storage")"; else record fail "$(t "リポジトリのパスがiCloud/File Provider配下です" "The repository is inside iCloud/File Provider storage")"; ACTION_ITEMS+=("$(t "~/Developer/ItJustTalksへ新しくcloneしてください。既存フォルダは移動・再利用しないでください。" "Make a new clone at ~/Developer/ItJustTalks. Do not move or reuse the existing folder.")"); fi
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then [[ -z "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]] && record ok "$(t "Git cloneはcleanです" "The Git clone is clean")" || record warn "$(t "Git cloneに未コミット変更があります" "The Git clone has uncommitted changes")"; else record fail "$(t "Git cloneとして確認できません" "This location is not a Git clone")"; fi

# Existing install is non-destructive normally and a hard failure for --install.
if itjusttalks_install_target_exists /Applications/ItJustTalks.app; then if [[ $INSTALL -eq 1 ]]; then record fail "$(t "/Applications/ItJustTalks.app が既に存在します（app・通常file・symlinkを上書きしません）" "/Applications/ItJustTalks.app already exists (app, regular file, and symlink are never overwritten)")"; ACTION_ITEMS+=("$(t "既存のItJustTalks.appを残すか手動で削除するかを判断してください。このスクリプトは変更しません。" "Decide whether to keep or manually remove the existing ItJustTalks.app. This script will not change it.")"); else record warn "$(t "/Applications/ItJustTalks.app が既に存在します。上書きする前に内容を確認してください" "/Applications/ItJustTalks.app already exists. Check it before overwriting.")"; fi; else record ok "$(t "/Applications/ItJustTalks.app はまだ存在しません" "/Applications/ItJustTalks.app does not exist yet")"; fi
available_kb="$(df -k "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"; [[ "$available_kb" =~ ^[0-9]+$ && "$available_kb" -ge 2097152 ]] && record ok "$(t "空きディスク容量は2GB以上あります" "At least 2GB of disk space is available")" || { record fail "$(t "空きディスク容量が不足しています（必要2GB以上）" "Not enough free disk space (2GB or more is required)")"; ACTION_ITEMS+=("$(t "空き容量を2GB以上確保してください。" "Free up at least 2GB of disk space.")"); }

if [[ $QUIET -eq 0 || $OVERALL_STATUS -ne 0 || ${#ACTION_ITEMS[@]} -gt 0 || $WARN_COUNT -gt 0 ]]; then print_report; fi
if [[ $OVERALL_STATUS -ne 0 ]]; then echo "$(t '結論: 停止（前提条件）' 'RESULT: blocked (prerequisites)')"
else
  case "$keychain_state" in
    absent) echo "$(t '結論: 署名用証明書の作成が必要' 'RESULT: needs-signing-cert')";;
    untrusted) echo "$(t '結論: 証明書の信頼設定が必要' 'RESULT: needs-trust')";;
    *) echo "$(t '結論: 準備完了' 'RESULT: ready')";;
  esac
fi
exit "$OVERALL_STATUS"
