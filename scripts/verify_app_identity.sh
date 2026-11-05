#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# ItJustTalks.app のbundle ID、コード署名、Designated Requirementを検証する。
#
# Usage:
#   bash scripts/verify_app_identity.sh <app>
#   bash scripts/verify_app_identity.sh <old-app> <new-app>
#   bash scripts/verify_app_identity.sh --signer-fingerprint <app>
#
# 2つの.appを渡した場合は、各.appの検証に加え、bundle IDとDesignated
# Requirementと署名者証明書が更新前後で連続していることを確認する。
# --signer-fingerprint はmake_app.sh内部でのみ使う機械可読な確認用。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ui_lang.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/install_checks.sh
source "$SCRIPT_DIR/lib/install_checks.sh"

usage() {
  printf '%s\n' "$(t "Usage:
  $0 <app>
  $0 <old-app> <new-app>
  $0 --signer-fingerprint <app>

  <app>                    1つのItJustTalks.appを検証する
  <old-app> <new-app>      更新前後の.appを検証し、識別と署名者の連続性を確認する
  --signer-fingerprint     署名者証明書のSHA-1を内部確認用に出力する" "Usage:
  $0 <app>
  $0 <old-app> <new-app>
  $0 --signer-fingerprint <app>

  <app>                    Verify one ItJustTalks.app
  <old-app> <new-app>      Verify both apps and check identity and signer continuity
  --signer-fingerprint     Output the signer certificate SHA-1 for internal checks")" >&2
  exit 1
}

fail() {
  echo "$(t "エラー: $*" "Error: $*")" >&2
  exit 1
}

if [[ "$#" -eq 2 && "$1" == "--signer-fingerprint" ]]; then
  output_mode="signer-fingerprint"
elif [[ "$#" -eq 1 || "$#" -eq 2 ]]; then
  output_mode="standard"
else
  usage
fi

validated_bundle_id=""
validated_requirement=""
validated_signer_fingerprint=""

verify_app() {
  local requested_path="$1"
  local app_path info_plist bundle_id bundle_icon_file ls_ui_element signed_metadata signed_identifier requirement_metadata requirement
  local certificate_directory certificate_prefix leaf_certificate signer_fingerprint codesign_log codesign_error

  [[ -d "$requested_path" ]] || fail "$(t "アプリが見つかりません: $requested_path" "App was not found: $requested_path")"
  app_path="$(cd "$requested_path" && pwd -P)"
  info_plist="$app_path/Contents/Info.plist"
  [[ -f "$info_plist" ]] || fail "$(t "Info.plistが見つかりません: $app_path" "Info.plist was not found: $app_path")"

  bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
  [[ -n "$bundle_id" ]] || fail "$(t "CFBundleIdentifierを読み取れません: $app_path" "Cannot read CFBundleIdentifier: $app_path")"

  case "$bundle_id" in
    com.itjusttalks.app|com.itjusttalks.onboarding-debug) ;;
    *) fail "$(t "想定外のbundle IDです: $bundle_id" "Unexpected bundle ID: $bundle_id")" ;;
  esac

  if [[ "$bundle_id" == "com.itjusttalks.app" ]]; then
    ls_ui_element="$(plutil -extract LSUIElement raw -o - "$info_plist" 2>/dev/null || true)"
    case "$ls_ui_element" in
      false|0) ;;
      *) fail "$(t "通常版はLSUIElement=falseでDock表示する必要があります: $app_path" "The standard app must use LSUIElement=false to appear in the Dock: $app_path")" ;;
    esac

    bundle_icon_file="$(plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null || true)"
    [[ "$bundle_icon_file" == "ItJustTalks.icns" ]] || fail "$(t "通常版のCFBundleIconFileがItJustTalks.icnsではありません: $app_path" "The standard app CFBundleIconFile is not ItJustTalks.icns: $app_path")"
    [[ -f "$app_path/Contents/Resources/$bundle_icon_file" ]] || fail "$(t "通常版のDockアイコンが見つかりません: $app_path" "The standard app Dock icon was not found: $app_path")"
    [[ -f "$app_path/Contents/Resources/ItJustTalksMenuBarTemplate.pdf" ]] || fail "$(t "通常版のメニューバーテンプレートPDFが見つかりません: $app_path" "The standard app menu bar template PDF was not found: $app_path")"
    [[ -f "$app_path/Contents/Resources/ja.lproj/Localizable.strings" ]] || fail "$(t "通常版の日本語文字列カタログが見つかりません: $app_path" "The standard app Japanese string catalog was not found: $app_path")"
    [[ -f "$app_path/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "$(t "通常版の英語文字列カタログが見つかりません: $app_path" "The standard app English string catalog was not found: $app_path")"
  else
    ls_ui_element="$(plutil -extract LSUIElement raw -o - "$info_plist" 2>/dev/null || true)"
    case "$ls_ui_element" in
      false|0) ;;
      *) fail "$(t "Debug版はLSUIElement=falseで確認用Windowを表示する必要があります: $app_path" "The Debug app must use LSUIElement=false to show its verification window: $app_path")" ;;
    esac
    [[ -f "$app_path/Contents/Resources/ja.lproj/Localizable.strings" ]] || fail "$(t "Debug版の日本語文字列カタログが見つかりません: $app_path" "The Debug app Japanese string catalog was not found: $app_path")"
    [[ -f "$app_path/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "$(t "Debug版の英語文字列カタログが見つかりません: $app_path" "The Debug app English string catalog was not found: $app_path")"
  fi

  codesign_log="$(mktemp "${TMPDIR:-/tmp}/itjusttalks-codesign.XXXXXX")" || fail "$(t "署名検証ログを作成できません。" "Cannot create the signature verification log.")"
  if ! codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>"$codesign_log"; then
    codesign_error="$(<"$codesign_log")"
    rm -f "$codesign_log"
    fail "$(t "コード署名の検証に失敗しました ($(itjusttalks_codesign_failure_class "$codesign_error")): $app_path${codesign_error:+$'\n'codesign: $codesign_error}" "Code signature verification failed ($(itjusttalks_codesign_failure_class "$codesign_error")): $app_path${codesign_error:+$'\n'codesign: $codesign_error}")"
  fi
  rm -f "$codesign_log"

  signed_metadata="$(codesign -dvv "$app_path" 2>&1)"
  signed_identifier="$(printf '%s\n' "$signed_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  [[ "$signed_identifier" == "$bundle_id" ]] || fail "$(t "署名のIdentifierとInfo.plistのbundle IDが一致しません: $app_path" "The signature Identifier does not match the Info.plist bundle ID: $app_path")"

  if [[ "$signed_metadata" == *"Signature=adhoc"* ]] || ! grep -q '^Authority=' <<<"$signed_metadata"; then
    fail "$(t "ad-hoc署名または信頼できる署名者のない.appです: $app_path" "The app has an ad-hoc signature or no trusted signer: $app_path")"
  fi

  requirement_metadata="$(codesign -d -r- "$app_path" 2>&1)"
  requirement="$(printf '%s\n' "$requirement_metadata" | sed -n -E 's/^[[:space:]]*(#[[:space:]]*)?designated => //p' | tail -n 1)"
  [[ -n "$requirement" ]] || fail "$(t "Designated Requirementを読み取れません: $app_path" "Cannot read the Designated Requirement: $app_path")"
  [[ "$requirement" == *"identifier \"$bundle_id\""* ]] || fail "$(t "Designated Requirementにbundle IDが含まれません: $app_path" "The Designated Requirement does not contain the bundle ID: $app_path")"

  certificate_directory="$(mktemp -d "${TMPDIR:-/tmp}/itjusttalks-signing.XXXXXX")" || fail "$(t "署名者証明書の検証用ディレクトリを作成できません。" "Cannot create a directory to verify the signer certificate.")"
  certificate_prefix="$certificate_directory/certificate"
  if ! codesign -d --extract-certificates="$certificate_prefix" "$app_path" >/dev/null 2>&1; then
    rm -rf "$certificate_directory"
    fail "$(t "署名者証明書を抽出できません: $app_path" "Cannot extract the signer certificate: $app_path")"
  fi
  leaf_certificate="${certificate_prefix}0"
  if [[ ! -f "$leaf_certificate" ]]; then
    rm -rf "$certificate_directory"
    fail "$(t "署名者証明書を読み取れません: $app_path" "Cannot read the signer certificate: $app_path")"
  fi
  signer_fingerprint="$(shasum -a 1 "$leaf_certificate" | awk '{ print toupper($1) }')"
  rm -rf "$certificate_directory"
  [[ "$signer_fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || fail "$(t "署名者証明書のSHA-1を読み取れません: $app_path" "Cannot read the signer certificate SHA-1: $app_path")"

  validated_bundle_id="$bundle_id"
  validated_requirement="$requirement"
  validated_signer_fingerprint="$signer_fingerprint"

  if [[ "$output_mode" == "standard" ]]; then
    echo "$(t "検証OK: $(basename "$app_path")" "Verification OK: $(basename "$app_path")")"
    echo "$(t "  bundle ID: $bundle_id" "  bundle ID: $bundle_id")"
    echo "$(t "  コード署名: 有効（非ad-hoc）" "  Code signature: valid (not ad-hoc)")"
    echo "$(t "  Designated Requirement: 取得済み" "  Designated Requirement: retrieved")"
    echo "$(t "  署名者証明書: 取得済み" "  Signer certificate: retrieved")"
  fi
}

if [[ "$output_mode" == "signer-fingerprint" ]]; then
  verify_app "$2"
  printf '%s\n' "$validated_signer_fingerprint"
  exit 0
fi

if [[ "$#" -eq 1 ]]; then
  verify_app "$1"
  exit 0
fi

verify_app "$1"
old_bundle_id="$validated_bundle_id"
old_requirement="$validated_requirement"
old_signer_fingerprint="$validated_signer_fingerprint"

verify_app "$2"
new_bundle_id="$validated_bundle_id"
new_requirement="$validated_requirement"
new_signer_fingerprint="$validated_signer_fingerprint"

[[ "$old_bundle_id" == "$new_bundle_id" ]] || fail "$(t "更新前後でbundle IDが変わっています。" "The bundle ID changed between app versions.")"
[[ "$old_requirement" == "$new_requirement" ]] || fail "$(t "更新前後でDesignated Requirementが変わっています。" "The Designated Requirement changed between app versions.")"
[[ "$old_signer_fingerprint" == "$new_signer_fingerprint" ]] || fail "$(t "更新前後で署名者証明書が変わっています。" "The signer certificate changed between app versions.")"

echo "$(t "更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。" "Update compatibility OK: bundle ID, Designated Requirement, and signer certificate are unchanged.")"
