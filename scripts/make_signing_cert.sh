#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# ローカル自己署名コード署名証明書 "ItJustTalks Dev" をログインkeychainに作成するスクリプト。
#
# 目的: ad-hoc署名（codesign -s -）はビルドごとにアイデンティティが変わり、TCC権限
# （マイク・音声認識・アクセシビリティ）が再ビルドのたびに無効化されてしまう。
# 安定した自己署名証明書を使うことで、再ビルド後もTCC権限を再登録せずに済む。
#
# 信頼済みならSHA-1を表示。未信頼なら既存証明書を再利用しmacOS認証で再開する。
# CIなど非対話環境では --non-interactive を渡すと、作成不可の場合でも失敗させず
# 状態だけを表示する。
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
「信頼」を展開し「コード署名」だけを「常に信頼」に変更し、macOSの認証を完了してください。
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
Expand Trust, set only Code Signing to Always Trust, and complete macOS authentication.
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


# Exit codes: 0 = a trusted code-signing identity is ready (or --non-interactive reported the state),
# 1 = stopped (duplicate certificates, inaccessible keychain, or a generation/import error),
# 3 = the certificate is registered but the trust dialog was cancelled or timed out (rerun to resume).
# Non-interactive mode never changes the keychain and never shows an authentication dialog.
KEYCHAIN_STATE="$(itjusttalks_keychain_state)"
if [[ $NON_INTERACTIVE -eq 1 ]]; then echo "$KEYCHAIN_STATE"; exit 0; fi
case "$KEYCHAIN_STATE" in
  found)
    echo "$(t "=== 証明書 \"$CERT_NAME\" は既に存在し、信頼設定済みです ===" "=== Certificate \"$CERT_NAME\" already exists and is trusted ===")"
    echo "SHA-1: $(existing_hash || true)"
    exit 0 ;;
  duplicate)
    echo "$(t "=== 停止: \"$CERT_NAME\" という証明書が複数あります ===" "=== Stopped: there is more than one certificate named \"$CERT_NAME\" ===")" >&2
    echo "$(t '新しい証明書は作りません。どれを残すかはご本人がキーチェーンアクセスで確認してください。' 'No new certificate is created. Check in Keychain Access which one to keep.')" >&2
    exit 1 ;;
  inaccessible)
    echo "$(t '=== 停止: キーチェーンにアクセスできません ===' '=== Stopped: the keychain is inaccessible ===')" >&2
    echo "$(t '証明書なしとは扱いません。ログインキーチェーンのロックを解除してから再実行してください。' 'This is not treated as a missing certificate. Unlock the login keychain and retry.')" >&2
    exit 1 ;;
esac

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
CERT_PATH="$WORKDIR/certificate.pem"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fail() {
  echo "$(t "=== 失敗: $1 ===" "=== Failed: $2 ===")" >&2
  echo "$(t "手作業での手順（最後の手段）: bash $0 --interactive-help" "Manual steps (last resort): bash $0 --interactive-help")" >&2
  exit 1
}

if [[ "$KEYCHAIN_STATE" == untrusted ]]; then
  # Reuse the single existing certificate: export it and run only the trust step.
  echo "$(t "=== 既存の証明書 \"$CERT_NAME\" を再利用し、信頼設定だけを行います ===" "=== Reusing the existing certificate \"$CERT_NAME\"; only the trust setting is needed ===")"
  # -c is a substring search, so bind the exported PEM to the SHA-1 of the exact-label entry.
  metadata="$(security find-certificate -a -Z -c "$CERT_NAME" "$LOGIN_KEYCHAIN" 2>/dev/null)" \
    || fail '既存の証明書を読み出せませんでした' 'Could not read the existing certificate'
  expected_hash="$(printf '%s\n' "$metadata" | awk '
    /^SHA-1 hash:/ {hash=$3}
    /"labl"<blob>="ItJustTalks Dev"$/ {print toupper(hash)}')"
  [[ "$expected_hash" =~ ^[[:xdigit:]]{40}$ ]] || fail '既存の証明書を特定できませんでした' 'Could not identify the existing certificate'
  security find-certificate -a -c "$CERT_NAME" -p "$LOGIN_KEYCHAIN" >"$WORKDIR/all.pem" 2>/dev/null \
    || fail '既存の証明書を書き出せませんでした' 'Could not export the existing certificate'
  awk -v dir="$WORKDIR" '
    /-----BEGIN CERTIFICATE-----/ {n++; file=dir "/export-" n ".pem"}
    n {print >file}
    /-----END CERTIFICATE-----/ {close(file)}
  ' "$WORKDIR/all.pem"
  matched=0
  for pem in "$WORKDIR"/export-*.pem; do
    [[ -f "$pem" ]] || continue
    fingerprint="$(/usr/bin/openssl x509 -in "$pem" -noout -fingerprint -sha1 2>/dev/null || true)"
    fingerprint="${fingerprint#*=}"
    fingerprint="$(printf '%s' "${fingerprint//:/}" | tr '[:lower:]' '[:upper:]')"
    if [[ "$fingerprint" == "$expected_hash" ]]; then
      cp "$pem" "$CERT_PATH"; matched=1; break
    fi
  done
  [[ $matched -eq 1 ]] || fail '既存の証明書を書き出せませんでした' 'Could not export the existing certificate'
else
  echo "$(t "=== 証明書 \"$CERT_NAME\" が見つからないため、新しく作成します ===" "=== Certificate \"$CERT_NAME\" was not found; creating it ===")"
  # OpenSSL 3 if present (needs -legacy for a PKCS#12 that macOS can import); otherwise macOS's
  # built-in LibreSSL, whose PKCS#12 export already uses the legacy RC2/3DES format.
  tool="$(itjusttalks_find_certificate_tool)" \
    || fail 'OpenSSL 3 も macOS標準のLibreSSL も見つかりません' 'Neither OpenSSL 3 nor macOS LibreSSL was found'
  IFS=$'\t' read -r kind OPENSSL_BIN <<<"$tool"
  KEY_PATH="$WORKDIR/key.pem"
  P12_PATH="$WORKDIR/certificate.p12"
  # A config file (instead of -addext) works with both LibreSSL and OpenSSL 3.
  cat >"$WORKDIR/req.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=ItJustTalks Dev
[extensions]
basicConstraints=critical,CA:true
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONFIG
  if ! "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORKDIR/req.cnf" \
      -keyout "$KEY_PATH" -out "$CERT_PATH" >"$WORKDIR/req.log" 2>&1; then
    cat "$WORKDIR/req.log" >&2
    fail '自己署名証明書を生成できませんでした' 'Could not generate the self-signed certificate'
  fi
  # This passphrase protects only the short-lived PKCS#12 file in WORKDIR. It is generated per run,
  # never printed, and becomes unusable when the trap removes that directory.
  P12_PASSWORD="$("$OPENSSL_BIN" rand -hex 32)"
  legacy_flag=""
  [[ "$kind" == openssl3 ]] && legacy_flag="-legacy"
  if ! P12_PASSWORD="$P12_PASSWORD" "$OPENSSL_BIN" pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" \
      -in "$CERT_PATH" -name "$CERT_NAME" -passout env:P12_PASSWORD $legacy_flag >"$WORKDIR/p12.log" 2>&1; then
    cat "$WORKDIR/p12.log" >&2
    fail '証明書を書き出せませんでした' 'Could not export the certificate'
  fi
  echo "$(t '=== ログインキーチェーンへ登録しています ===' '=== Registering it in the login keychain ===')"
  if ! security import "$P12_PATH" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null; then
    fail '登録できませんでした（ログインキーチェーンがロックされている可能性があります）' 'Could not register it (the login keychain may be locked)'
  fi
  unset P12_PASSWORD
  rm -f "$KEY_PATH" "$P12_PATH"
fi

# Trust only for the code-signing policy (-p codeSign). This shows a macOS authentication dialog
# (Touch ID or password) that only the user can approve; it can never be approved by a script.
# If it fails, never retry with broader trust. The timeout only avoids waiting forever for someone
# who left the Mac; it must not be shorter than a person needs for Touch ID or a password.
echo ""
echo "$(t 'これから macOS の認証画面が出ます。Touch ID またはパスワードで承認してください。' 'A macOS authentication dialog will appear. Approve it with Touch ID or your password.')"
echo "$(t '（この証明書を「コード署名」の用途に限って信頼するための、macOSが求める手順です）' '(macOS requires this step to trust this certificate for code signing only.)')"
trust_status=0
TRUST_LOG="$WORKDIR/trust.log"
if command -v timeout >/dev/null 2>&1; then
  timeout 180 security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$CERT_PATH" 2>"$TRUST_LOG" || trust_status=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 180 security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$CERT_PATH" 2>"$TRUST_LOG" || trust_status=$?
else
  security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$CERT_PATH" 2>"$TRUST_LOG" || trust_status=$?
fi
if [[ $trust_status -eq 0 ]]; then
  if [[ "$(itjusttalks_keychain_state)" == found ]]; then
    echo "$(t "=== 証明書 \"$CERT_NAME\" の準備ができました（コード署名用に信頼済み） ===" "=== Certificate \"$CERT_NAME\" is ready (trusted for code signing) ===")"
    echo "SHA-1: $(existing_hash || true)"
    exit 0
  fi
  # Trust was added but the certificate still is not a usable signing identity (for example the
  # private key is missing or the certificate expired). Rerunning would only repeat the dialog.
  echo "$(t '=== 停止: 信頼設定はできましたが、署名に使える状態になりません ===' '=== Stopped: trust was added, but the certificate is still not usable for signing ===')" >&2
  echo "$(t '秘密鍵が無い・期限切れなどの可能性があります。再実行しても解決しないため、説明書の付録B「困った時」を確認してください。' 'The private key may be missing or the certificate may have expired. Rerunning will not fix this; see "Troubleshooting" in Appendix B of the manual.')" >&2
  exit 1
fi
cat "$TRUST_LOG" >&2
# Only a cancelled or timed-out authentication is resumable (exit 3). Any other failure stops (exit 1)
# so that callers do not loop on a dialog that cannot succeed. Trust is never retried more broadly.
if [[ $trust_status -eq 124 ]] || grep -qiE 'cancel|-60006|-128|user interaction|interaction is not allowed' "$TRUST_LOG"; then
  echo "$(t '=== 証明書の登録は済んでいますが、信頼設定が完了していません ===' '=== The certificate is registered, but trust is not complete ===')" >&2
  echo "$(t '認証画面を閉じた・時間切れになった場合は、このスクリプトを再実行すると続きから再開します（新しい証明書は作りません）。' 'If the dialog was cancelled or timed out, rerun this script to resume (no new certificate is created).')" >&2
  exit 3
fi
echo "$(t '=== 停止: 信頼設定に失敗しました ===' '=== Stopped: the trust setting failed ===')" >&2
echo "$(t "証明書は登録済みです。上のエラーを確認してください。手作業での手順（最後の手段）: bash $0 --interactive-help" "The certificate is registered. Check the error above. Manual steps (last resort): bash $0 --interactive-help")" >&2
exit 1
