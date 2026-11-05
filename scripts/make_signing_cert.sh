#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# ローカル自己署名コード署名証明書 "ItJustTalks Dev" をログインkeychainに作成するスクリプト。
#
# 目的: ad-hoc署名（codesign -s -）はビルドごとにアイデンティティが変わり、TCC権限
# （マイク・音声認識・アクセシビリティ）が再ビルドのたびに無効化されてしまう。
# 安定した自己署名証明書を使うことで、再ビルド後もTCC権限を再登録せずに済む。
#
# 既に "ItJustTalks Dev" 証明書が存在すればスキップし、証明書のSHA-1ハッシュを出力する。
# CIなど非対話環境では --non-interactive を渡すと、作成不可の場合でも失敗させず
# メッセージを出してスキップする。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ui_lang.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/install_checks.sh
source "$SCRIPT_DIR/lib/install_checks.sh"

CERT_NAME="ItJustTalks Dev"
NON_INTERACTIVE=0
INTERACTIVE_HELP=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --interactive-help) INTERACTIVE_HELP=1 ;;
    *) ;;
  esac
done

if [[ "$INTERACTIVE_HELP" -eq 1 ]]; then
  printf '%s\n' "$(t '=== 既存証明書の信頼修復 ===
「キーチェーンアクセス.app」で「ログイン」の "ItJustTalks Dev" を検索し、ダブルクリック。
「信頼」を展開し「コード署名」を「常に信頼」に変更し、macOSの認証を完了してください。
既存証明書がある場合は新しく作成しないでください。crtファイルは不要です。

=== 証明書がない場合の手動作成手順 ===
1. 「キーチェーンアクセス.app」を開く
2. メニューバー: キーチェーンアクセス → 証明書アシスタント → 証明書を作成...
3. 名前: "ItJustTalks Dev"
4. identity種類: 自己署名ルート
5. 証明書の種類: コード署名
6. 「デフォルトを上書き」にチェックし、鍵ペア用途を「このアイテムのデフォルトを常に使用」から
   コード署名を確実に含める設定にして作成
7. 作成後、「ログイン」キーチェーンに保存されていることを確認
8. ターミナルで `security find-identity -v -p codesigning` を実行し、
   "ItJustTalks Dev" が一覧に出ることを確認する

作成後、このスクリプトを再実行すればハッシュが表示されます。' '=== Repair trust for an existing certificate ===
Open Keychain Access, find "ItJustTalks Dev" in the login Keychain, and double-click it.
Expand Trust, set Code Signing to Always Trust, and complete macOS authentication.
Do not create another certificate if one already exists. No crt file is needed.

=== Manually create a certificate if none exists ===
1. Open Keychain Access.
2. From the menu, choose Keychain Access → Certificate Assistant → Create a Certificate...
3. Name: "ItJustTalks Dev"
4. Identity Type: Self Signed Root
5. Certificate Type: Code Signing
6. Select Let me override defaults. Configure key pair usage to explicitly include
   code signing rather than Always use defaults for this item, then create it.
7. Confirm that it is saved in the login Keychain.
8. Run `security find-identity -v -p codesigning` in Terminal and confirm that
   "ItJustTalks Dev" appears in the list.

After creation, rerun this script to display the hash.')"
  exit 0
fi

existing_hash() {
  local output status
  output="$(security find-identity -v -p codesigning 2>&1)"; status=$?
  [[ $status -eq 0 ]] || return "$status"
  printf '%s\n' "$output" | awk -v certificate_name="$CERT_NAME" \
    'index($0, "\"" certificate_name "\"") && $2 ~ /^[[:xdigit:]]{40}$/ { print toupper($2); exit }'
}

# codesigning用アイデンティティ（信頼済み）として既に使える場合。
KEYCHAIN_STATE="$(itjusttalks_keychain_state)"
if [[ "$KEYCHAIN_STATE" == inaccessible ]]; then
  echo "$(t '=== 失敗: Keychainにアクセスできません ===' "=== Failed: Cannot access the Keychain ===")" >&2
  echo "$(t '証明書なしとして扱わず、Keychainを解除してから再実行してください。' "Unlock the Keychain and retry. This is not treated as a missing certificate.")" >&2
  exit 1
fi
HASH="$(existing_hash || true)"
if [[ -n "$HASH" ]]; then
  echo "$(t "=== 証明書 \"$CERT_NAME\" は既に存在し、信頼設定済みです ===" "=== Certificate \"$CERT_NAME\" already exists and is trusted ===")"
  echo "$(t "SHA-1: $HASH" "SHA-1: $HASH")"
  exit 0
fi

# keychainに証明書自体は存在するが信頼設定が未完了の場合（再実行での重複作成を防ぐ）。
# 冪等性のため、この時点で既に証明書がkeychainにあれば新規作成せず案内のみ再表示する。
EXISTING_CERT_IN_KEYCHAIN="$(security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -c "labl" || true)"
if [[ "${EXISTING_CERT_IN_KEYCHAIN:-0}" -gt 0 ]]; then
  echo "$(t "=== 証明書 \"$CERT_NAME\" はkeychainに既に存在しますが、信頼設定（Trust）が未完了です ===" "=== Certificate \"$CERT_NAME\" exists in the Keychain, but trust setup is incomplete ===")"
  PERSISTENT_CERT_DIR="$HOME/Library/Application Support/ItJustTalks"
  PERSISTENT_CERT_PATH="$PERSISTENT_CERT_DIR/itjusttalks_dev_cert.crt"
  if [[ -f "$PERSISTENT_CERT_PATH" ]]; then
    echo "$(t "信頼設定を完了するには以下を実行し、認証ダイアログで承認してください:" "To complete trust setup, run the following and approve the authentication dialog:")" >&2
    echo "$(t "  security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"" "  security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"")" >&2
  else
    echo "$(t "手動作成手順: bash $0 --interactive-help" "Manual setup instructions: bash $0 --interactive-help")" >&2
  fi
  exit 0
fi

echo "$(t "=== 証明書 \"$CERT_NAME\" が見つかりません ===" "=== Certificate \"$CERT_NAME\" was not found ===")"


if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
  echo "$(t "非対話モードのため証明書作成をスキップします。" "Skipping certificate creation in non-interactive mode.")"
  echo "$(t "手動作成手順が必要な場合は: bash $0 --interactive-help" "For manual setup instructions: bash $0 --interactive-help")"
  exit 0
fi

# macOS標準の/usr/bin/opensslはLibreSSLで、-legacy等のOpenSSL 3専用オプションを解さない。
# 事前に実体を判定し、OpenSSL 3でなければ代替パスを探す。見つからなければ、40行以上の
# usageダンプをユーザーに見せる前に、ここで日本語メッセージを出して停止する。
if ! OPENSSL_BIN="$(itjusttalks_find_openssl3)"; then
  echo "$(t "=== 失敗: OpenSSL 3が見つかりません ===" "=== Failed: OpenSSL 3 was not found ===")" >&2
  echo "$(t "候補はPATHと既知のHomebrew場所について実体の version 出力で検証しました。" "Candidates on PATH and in known Homebrew locations were checked using their version output.")" >&2
  echo "$(t "以下を実行してOpenSSL 3を導入してから再実行してください:" "Install OpenSSL 3 with the following command, then retry:")" >&2
  echo "$(t "  brew install openssl@3" "  brew install openssl@3")" >&2
  exit 1
fi

# 自己署名コード署名証明書を自動生成する。
# security create-keychainは使わず、既定のログインkeychainへ証明書を追加する形を取る。
# opensslで自己署名証明書＋秘密鍵を生成し、PKCS#12として一時的にエクスポートしてから
# securityコマンドでログインkeychainへインポートする（ユーザーのkeychainパスワード入力を
# 極力避けるため、既にアンロック状態のログインkeychainへの追加を試みる）。
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KEY_PATH="$WORKDIR/itjusttalks_dev.key"
CERT_PATH="$WORKDIR/itjusttalks_dev.crt"
P12_PATH="$WORKDIR/itjusttalks_dev.p12"
# This passphrase protects only the short-lived PKCS#12 file in WORKDIR.  It is
# generated per run, never printed, and becomes unusable when the trap removes
# that directory.
P12_PASSWORD="$("$OPENSSL_BIN" rand -hex 32)"

echo "$(t "=== 自己署名証明書を生成しています ===" "=== Generating a self-signed certificate ===")"
REQ_LOG="$WORKDIR/openssl_req.log"
if ! "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" -out "$CERT_PATH" \
  -days 3650 -nodes -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >"$REQ_LOG" 2>&1; then
  echo "$(t "=== 失敗: 自己署名証明書の生成に失敗しました ===" "=== Failed: Could not generate the self-signed certificate ===")" >&2
  cat "$REQ_LOG" >&2
  exit 1
fi

# -legacy: OpenSSL 3.x はデフォルトでAES暗号化のPKCS#12を生成するが、macOSの
# securityコマンド（SecKeychainItemImport）はこれを正しく復号できずMAC検証エラーになる
# 場合がある。-legacyでRC2/3DES系の従来形式にすることでmacOS側と互換性を持たせる。
# OPENSSL_BINはOpenSSL 3であることを確認済みのため、-legacyオプションが解釈される。
P12_PASSWORD="$P12_PASSWORD" "$OPENSSL_BIN" pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" -in "$CERT_PATH" \
  -name "$CERT_NAME" -passout env:P12_PASSWORD -legacy

echo "$(t "=== ログインkeychainへインポートしています ===" "=== Importing into the login Keychain ===")"
if security import "$P12_PATH" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security; then
  echo "$(t "インポートに成功しました。" "Import succeeded.")"
else
  echo "$(t "インポートに失敗しました。keychainがロックされている可能性があります。" "Import failed. The Keychain may be locked.")" >&2
  echo "$(t "手動作成手順: bash $0 --interactive-help" "Manual setup instructions: bash $0 --interactive-help")" >&2
  exit 1
fi

# コード署名で使えるように、信頼設定に「常に信頼」を付与する（自己署名のため必要）。
# 重要: `add-trusted-cert` はGUIの認証ダイアログ（Touch ID/パスワード入力）を要求する。
# これは意図的なOSのセキュリティゲートであり、非対話シェルからは絶対に自動承認できない。
# timeout/gtimeoutが使えればそれで打ち切るが、どちらも無い素のmacOS環境ではタイムアウトせず
# 直接実行する（承認されるまでブロックするのは、導入作業中は正しい挙動のため）。
# 打ち切りは「席を外した人を無限に待たない」ための保険であって、承認そのものを
# 急かすためのものではない。Touch IDやパスワード入力に人間が要する時間より短くしない。
TRUST_TIMEOUT_SECONDS=180
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
else
  TIMEOUT_CMD=""
fi

echo "$(t "" "")"
echo "$(t "これから macOS の認証ダイアログが表示されます。Touch ID またはパスワードで承認してください。" "A macOS authentication dialog will appear. Approve it with Touch ID or your password.")"
echo "$(t "これは自己署名証明書をコード署名用として信頼させるための、macOS が要求する手順です。" "macOS requires this step to trust the self-signed certificate for code signing.")"

TRUST_ADDED=0
# `-r trustAsRoot` は自己署名ルート証明書向けの厳格な設定だが、macOSによっては
# `SecTrustSettingsSetTrustSettings: parameters were not valid` エラーで拒否されることがある。
# `-r trustAsRoot` を省略した通常のadd-trusted-certでも codeSigning EKU を持つ自己署名証明書は
# `find-identity -p codesigning` に登録されるため、まずこちらを試す。
if [[ -n "$TIMEOUT_CMD" ]]; then
  if $TIMEOUT_CMD "$TRUST_TIMEOUT_SECONDS" security add-trusted-cert -k "$HOME/Library/Keychains/login.keychain-db" "$CERT_PATH"; then
    TRUST_ADDED=1
  fi
else
  if security add-trusted-cert -k "$HOME/Library/Keychains/login.keychain-db" "$CERT_PATH"; then
    TRUST_ADDED=1
  fi
fi

NEW_HASH="$(existing_hash || true)"

if [[ "$TRUST_ADDED" -eq 1 && -n "$NEW_HASH" ]]; then
  echo "$(t "=== 証明書 \"$CERT_NAME\" を作成し、信頼設定も完了しました ===" "=== Certificate \"$CERT_NAME\" was created and trust setup is complete ===")"
  echo "$(t "SHA-1: $NEW_HASH" "SHA-1: $NEW_HASH")"
  exit 0
fi

# 証明書自体はkeychainに存在するがcodesigning用アイデンティティとしては未認識
# （信頼設定が付与されていない）。keychainから証明書を永続パスへ再エクスポートし、
# WORKDIR削除後も手動コマンドが使えるようにしておく。
PERSISTENT_CERT_DIR="$HOME/Library/Application Support/ItJustTalks"
# 証明書の置き場は本人だけが読めるようにする（このスクリプトが作る場合は 700）。
mkdir -m 700 -p "$PERSISTENT_CERT_DIR"
PERSISTENT_CERT_PATH="$PERSISTENT_CERT_DIR/itjusttalks_dev_cert.crt"
security find-certificate -c "$CERT_NAME" -p "$HOME/Library/Keychains/login.keychain-db" > "$PERSISTENT_CERT_PATH" 2>/dev/null || \
  cp "$CERT_PATH" "$PERSISTENT_CERT_PATH"

CERT_HASH="$("$OPENSSL_BIN" x509 -in "$PERSISTENT_CERT_PATH" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')"
echo "$(t "=== 証明書 \"$CERT_NAME\" はkeychainに作成されましたが、信頼設定（Trust）が未完了です ===" "=== Certificate \"$CERT_NAME\" was created in the Keychain, but trust setup is incomplete ===")" >&2
echo "$(t "SHA-1 (証明書): ${CERT_HASH:-不明}" "SHA-1 (certificate): ${CERT_HASH:-unknown}")" >&2
echo "$(t "" "")" >&2
echo "$(t "macOSの仕様上、自己署名証明書を codesign で使えるようにする「常に信頼」設定は" "To enable a self-signed certificate for codesign, macOS requires the Always Trust setting.")" >&2
echo "$(t "GUIの認証ダイアログでの明示的な承認が必須で、スクリプトから自動化できません。" "You must explicitly approve the authentication dialog; a script cannot automate this approval.")" >&2
echo "$(t "以下のいずれかの方法で信頼設定を完了してください:" "Complete trust setup using either method below:")" >&2
echo "$(t "  1. 「キーチェーンアクセス.app」を開き、\"$CERT_NAME\" を検索 → ダブルクリック →" "  1. Open Keychain Access, search for \"$CERT_NAME\", double-click it, then")" >&2
echo "$(t "     「信頼」セクションを展開 → 「コード署名」を「常に信頼」に変更" "     expand Trust and set Code Signing to Always Trust.")" >&2
echo "$(t "  2. またはターミナルで以下を実行し、表示される認証ダイアログで承認する:" "  2. Or run the following in Terminal and approve the authentication dialog:")" >&2
echo "$(t "     security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"" "     security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"")" >&2
echo "$(t "" "")" >&2
echo "$(t "信頼設定完了後、'security find-identity -v -p codesigning' に \"$CERT_NAME\" が表示されます。" "After trust setup, 'security find-identity -v -p codesigning' will list \"$CERT_NAME\".")" >&2
echo "$(t "信頼設定が完了するまで、scripts/make_app.sh は安全のため.appの作成を停止します。" "Until trust setup is complete, scripts/make_app.sh will stop app creation for safety.")" >&2
# 証明書自体の作成（keychainへの追加）は成功しているため、スクリプトとしては成功終了とする。
# 「codesign実行可能な状態への到達」は信頼設定の手動承認という別ステップであり、
# それが未完了であること自体はこのスクリプトの失敗ではない。
exit 0
