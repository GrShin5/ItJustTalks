#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# Install only a verified, signed dist/ItJustTalks.app.  No arguments are accepted.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ui_lang.sh"

[[ $# -eq 0 ]] || { echo "$(t "Usage: $0" "Usage: $0")" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE_APP="$ROOT_DIR/dist/ItJustTalks.app"
TARGET_APP="/Applications/ItJustTalks.app"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || { echo "$(t "エラー: 入力appがありません: $SOURCE_APP" "Error: The source app was not found: $SOURCE_APP")" >&2; exit 2; }
if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
  echo "$(t "エラー: インストール先は既に存在するため上書きしません: $TARGET_APP" "Error: The installation target already exists and will not be overwritten: $TARGET_APP")" >&2; exit 2
fi
TARGET_PARENT="$(dirname "$TARGET_APP")"
[[ -d "$TARGET_PARENT" && ! -L "$TARGET_PARENT" ]] || { echo "$(t "エラー: インストール先の親ディレクトリが安全ではありません" "Error: The installation target parent directory is unsafe.")" >&2; exit 2; }
TEMP_ROOT="$(mktemp -d "$TARGET_PARENT/.itjusttalks-install.XXXXXX")"
TEMP_APP="$TEMP_ROOT/ItJustTalks.app"
CLAIMED_TARGET=0
CLAIMED_TARGET_ID=""
# TEMP_ROOT was created by mktemp directly below the fixed target parent.  Never
# remove a caller-provided path or an existing installation target.
owns_claimed_target() {
  [[ "$CLAIMED_TARGET" -eq 1 && -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || return 1
  [[ "$(stat -f '%d:%i' "$TARGET_APP" 2>/dev/null || true)" == "$CLAIMED_TARGET_ID" ]]
}
cleanup() {
  [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT"
  if owns_claimed_target; then
    rm -rf "$TARGET_APP"
  fi
  return 0
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$TEMP_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$TEMP_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP" "$TEMP_APP"
# mkdir is the no-clobber claim: a competing app/file/symlink makes it fail,
# and we never pass an existing directory to mv (which could nest the bundle).
if ! mkdir "$TARGET_APP"; then
  echo "$(t "エラー: インストール先が競合したため上書きせず停止しました" "Error: Stopped without overwriting because another item appeared at the installation target.")" >&2; exit 2
fi
CLAIMED_TARGET=1
CLAIMED_TARGET_ID="$(stat -f '%d:%i' "$TARGET_APP" 2>/dev/null || true)"
[[ -n "$CLAIMED_TARGET_ID" ]] || { echo "$(t "エラー: インストール先の所有確認に失敗しました" "Error: Could not confirm ownership of the installation target.")" >&2; exit 2; }
owns_claimed_target || { echo "$(t "エラー: インストール先が検証中に置き換えられました" "Error: The installation target was replaced during verification.")" >&2; exit 2; }
mv "$TEMP_APP/Contents" "$TARGET_APP/Contents"
[[ ! -e "$TEMP_APP/Contents" && -d "$TARGET_APP/Contents" ]] || { echo "$(t "エラー: 一時appを確定できませんでした" "Error: Could not finalize the temporary app.")" >&2; exit 2; }
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP" "$TARGET_APP"
CLAIMED_TARGET=0
# macOS にバンドルの更新を通知する。
if ! touch "$TARGET_APP"; then
  echo "$(t "警告: アイコン表示の更新通知に失敗しました（インストールは完了しています）" "Warning: Could not notify macOS to refresh the icon (installation is complete).")" >&2 || true
fi
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  if ! "$LSREGISTER" -f "$TARGET_APP"; then
    echo "$(t "警告: アイコン表示の更新通知に失敗しました（インストールは完了しています）" "Warning: Could not notify macOS to refresh the icon (installation is complete).")" >&2 || true
  fi
fi
rm -rf "$TEMP_ROOT"; TEMP_ROOT=""
echo "$(t "インストールOK: $TARGET_APP" "Installation OK: $TARGET_APP")"
