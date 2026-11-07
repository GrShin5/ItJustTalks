#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# One-command, non-destructive installation of ItJustTalks from this source folder.
#   bash scripts/install.sh                       # stops (exit 3) if a certificate must be created/trusted
#   bash scripts/install.sh --allow-signing-cert  # the user approved certificate creation/registration
#                                                 # and code-signing-only trust (macOS dialog)
# Exit codes: 0 installed (or already installed), 2 stopped by a failed check, 3 waiting for the user.
# Rerunning after fixing the cause resumes safely: the certificate is reused, the build is redone,
# and nothing is ever overwritten.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/ui_lang.sh"
source "$SCRIPT_DIR/lib/install_checks.sh"

usage() { echo "Usage: bash scripts/install.sh [--allow-signing-cert]"; }
allow=0
for arg in "$@"; do
  case "$arg" in
    --allow-signing-cert) allow=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
cd "$SCRIPT_DIR/.."

APP=dist/ItJustTalks.app
TARGET=/Applications/ItJustTalks.app
step() { echo ""; echo "=== $1 ==="; }
stop() {
  echo "" >&2
  echo "$(t '=== 停止しました ===' '=== Stopped ===')" >&2
  echo "$(t 'あなたがやること' 'What you need to do'): $2" >&2
  exit "$1"
}
plist_value() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

step "$(t '1/6 事前確認' '1/6 Prerequisite check')"
bash "$SCRIPT_DIR/preflight.sh" || stop 2 "$(t '上の「あなたがやること」を解決してから、同じコマンドを再実行してください。' 'Resolve the items under "What you need to do" above, then rerun the same command.')"

# An existing app is never replaced here. If it is exactly this source revision, there is nothing to do.
if itjusttalks_install_target_exists "$TARGET"; then
  step "$(t '既存のアプリを確認' 'Checking the existing app')"
  head_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"  # same form as make_app.sh writes
  if [[ -d "$TARGET" && ! -L "$TARGET" && -n "$head_commit" \
        && "$(plist_value "$TARGET" ItJustTalksBuildGitSHA)" == "$head_commit" ]] \
     && bash "$SCRIPT_DIR/verify_app_identity.sh" "$TARGET"; then
    echo "$(t "このソース（$head_commit）から作ったアプリは既にインストール済みです: $TARGET" "An app built from this source ($head_commit) is already installed: $TARGET")"
    exit 0
  fi
  stop 2 "$(t "$TARGET が既にあります。新規導入では上書きしません。更新用プロンプト（docs/agent-update-prompt.md）か説明書の付録Dの手順で更新してください。既存のアプリは変更していません。" "$TARGET already exists. A new installation never overwrites it. Update it with the update prompt (docs/agent-update-prompt.en.md) or Appendix D of the manual. The existing app was not changed.")"
fi

step "$(t '2/6 署名用証明書' '2/6 Signing certificate')"
state="$(itjusttalks_keychain_state)"
case "$state" in
  found)
    echo "$(t '既存の署名用証明書を使います。' 'Using the existing signing certificate.')" ;;
  absent|untrusted)
    if [[ $allow -ne 1 ]]; then
      stop 3 "$(t '署名用証明書「ItJustTalks Dev」の作成（未作成の場合）とログインキーチェーンへの登録、コード署名だけに限った信頼設定が必要です。内容を確認して承認したら、bash scripts/install.sh --allow-signing-cert を実行してください。途中でmacOSの認証画面が出たら、Touch IDかパスワードで承認してください。' 'The signing certificate "ItJustTalks Dev" must be created (if missing), registered in the login keychain, and trusted for code signing only. After you review and approve this, run bash scripts/install.sh --allow-signing-cert. When the macOS authentication dialog appears, approve it with Touch ID or your password.')"
    fi
    cert_status=0
    bash "$SCRIPT_DIR/make_signing_cert.sh" || cert_status=$?
    case "$cert_status" in
      0) ;;
      3) stop 3 "$(t '証明書の登録は済んでいますが、信頼設定が完了していません。同じコマンドを再実行し、macOSの認証画面で承認してください。' 'The certificate is registered, but trust is not complete. Rerun the same command and approve the macOS authentication dialog.')" ;;
      *) stop 2 "$(t '上に表示された証明書の問題を解決してから再実行してください。' 'Resolve the certificate problem shown above, then rerun.')" ;;
    esac ;;
  duplicate)
    stop 2 "$(t '「ItJustTalks Dev」という証明書が複数あります。どれを使うか自動では決められないため、新しく作らずに止まりました。説明書の付録B「困った時」を確認してください。' 'There is more than one certificate named "ItJustTalks Dev". The script cannot choose one automatically, so it stopped without creating another. See "Troubleshooting" in Appendix B of the manual.')" ;;
  *)
    stop 2 "$(t 'キーチェーンにアクセスできません。ログインキーチェーンのロックを解除してから再実行してください（証明書は削除・作り直ししないでください）。' 'The keychain is inaccessible. Unlock the login keychain and rerun (do not delete or recreate the certificate).')" ;;
esac

step "$(t '3/6 アプリの組み立て（release）' '3/6 Building the app (release)')"
bash "$SCRIPT_DIR/make_app.sh" release || stop 2 "$(t '上に表示されたビルドの問題を解決してから再実行してください。' 'Resolve the build problem shown above, then rerun.')"

step "$(t '4/6 アプリの検証' '4/6 Verifying the app')"
bash "$SCRIPT_DIR/verify_app_identity.sh" "$APP" || stop 2 "$(t '署名の検証に失敗しました。検証を省略せず、上の説明に従ってください。' 'Signature verification failed. Do not skip verification; follow the explanation above.')"

step "$(t '5/6 インストール' '5/6 Installing')"
bash "$SCRIPT_DIR/preflight.sh" --install --quiet || stop 2 "$(t '上のインストール前確認の問題を解決してから再実行してください。' 'Resolve the pre-installation problem shown above, then rerun.')"
bash "$SCRIPT_DIR/install_app.sh" || stop 2 "$(t '上に表示されたインストールの問題を解決してください。' 'Resolve the installation problem shown above.')"

step "$(t '6/6 インストール後の照合' '6/6 Checking the installed app')"
bash "$SCRIPT_DIR/verify_app_identity.sh" "$APP" "$TARGET" || stop 2 "$(t 'インストール後の照合に失敗しました。アプリを起動せず、結果を確認してください。' 'The post-installation check failed. Do not launch the app; review the results.')"

echo ""
echo "$(t '=== 完了 ===' '=== Done ===')"
echo "$(t 'インストール先' 'Installed at'): $TARGET"
echo "$(t 'バージョン' 'Version'): $(plist_value "$TARGET" CFBundleShortVersionString)"
echo "$(t 'ソースのコミット' 'Source commit'): $(git rev-parse HEAD 2>/dev/null || echo "?")"
echo "$(t '署名の検証: OK' 'Signature verification: OK')"
echo ""
echo "$(t '残っている確認（ご本人の操作）:' 'Remaining checks (done by you):')"
echo "$(t '1. Finderの「アプリケーション」からItJustTalksを起動する' '1. Launch ItJustTalks from Applications in Finder')"
echo "$(t '2. マイク・音声認識・アクセシビリティを許可する' '2. Allow Microphone, Speech Recognition, and Accessibility')"
echo "$(t '3. Apple Intelligenceがオンで、MacとSiriの言語が一致しているか確認する' '3. Check that Apple Intelligence is on and the Mac and Siri languages match')"
echo "$(t '4. 「今日はテストです」などの短い文で、キーと入力を試す' '4. Try the keys and input with a short sentence such as "This is a test"')"
echo "$(t 'インストールの成功は、実際の動作確認の合格ではありません。' 'A successful installation is not a passed device test.')"
