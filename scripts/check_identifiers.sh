#!/bin/bash
# Fail if any tracked file still names the upstream project (case-insensitive
# "koedex") outside scripts/identifier_allowlist.txt.
# Checks paths, contents (binary files included) and symlink targets of tracked files
# (plus untracked, non-ignored files so new files are caught before they are committed).
# Also fails if "applicationSupportDirectory" appears under Sources/ outside the two
# approved files (storage must go through the ItJustTalks-specific path helpers). Read-only.
# Usage: scripts/check_identifiers.sh
# Exit: 0 = no violations, 1 = violations found, 2 = usage/environment error.
set -euo pipefail

[[ "$#" -eq 0 ]] || { echo "Usage: $0" >&2; exit 2; }
cd "$(dirname "$0")/.."
ALLOWLIST="scripts/identifier_allowlist.txt"
PATTERN="koedex"
[[ -f "$ALLOWLIST" ]] || { echo "error: $ALLOWLIST not found" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: not a git work tree" >&2; exit 2; }

ALLOW_GLOBS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] && ALLOW_GLOBS+=("$line")
done < "$ALLOWLIST"

is_allowed() {
  local path="$1" glob
  for glob in "${ALLOW_GLOBS[@]}"; do
    # Unquoted right-hand side: glob match, where "*" also matches "/".
    # shellcheck disable=SC2053
    [[ "$path" == $glob ]] && return 0
  done
  return 1
}

total_hits=0
allowed_hits=0
violation_hits=0
VIOLATIONS=()
while IFS= read -r -d '' path; do
  hits=0
  path_lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  [[ "$path_lower" == *"$PATTERN"* ]] && hits=1
  content_hits=0
  if [[ -L "$path" ]]; then
    link_target="$(readlink -- "$path" || true)"
    link_lower="$(printf '%s' "$link_target" | tr '[:upper:]' '[:lower:]')"
    [[ "$link_lower" == *"$PATTERN"* ]] && content_hits=1
  elif [[ -f "$path" ]]; then
    content_hits="$(grep -aic -- "$PATTERN" "$path" || true)"
  fi
  hits=$((hits + content_hits))
  [[ "$hits" -gt 0 ]] || continue
  total_hits=$((total_hits + hits))
  if is_allowed "$path"; then
    allowed_hits=$((allowed_hits + hits))
  else
    violation_hits=$((violation_hits + hits))
    VIOLATIONS+=("$path ($hits)")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

# Rule 2: direct use of the shared Application Support directory is limited to two files.
APPSUPPORT_ALLOWED=(
  "Sources/ItJustTalks/Permissions/OnboardingRuntimeProfile.swift"
  "Sources/ItJustTalks/Support/RegressionTestSuite.swift"
)
APPSUPPORT_VIOLATIONS=()
while IFS= read -r -d '' path; do
  [[ -f "$path" && ! -L "$path" ]] || continue
  skip=0
  for allowed in "${APPSUPPORT_ALLOWED[@]}"; do
    [[ "$path" == "$allowed" ]] && skip=1
  done
  [[ "$skip" -eq 1 ]] && continue
  while IFS= read -r hit; do
    [[ -n "$hit" ]] && APPSUPPORT_VIOLATIONS+=("$path:${hit%%:*}")
  done < <(grep -an -- "applicationSupportDirectory" "$path" || true)
done < <(git ls-files -z --cached --others --exclude-standard -- Sources)

echo "identifier check: total hits before allowlist: $total_hits"
echo "identifier check: allowlisted hits: $allowed_hits"
echo "identifier check: violations: $violation_hits"
status=0
if [[ "${#VIOLATIONS[@]}" -gt 0 ]]; then
  echo "Files naming the upstream project outside $ALLOWLIST:" >&2
  printf '  %s\n' "${VIOLATIONS[@]}" >&2
  status=1
fi
if [[ "${#APPSUPPORT_VIOLATIONS[@]}" -gt 0 ]]; then
  echo "applicationSupportDirectory used outside the approved files:" >&2
  printf '  %s\n' "${APPSUPPORT_VIOLATIONS[@]}" >&2
  status=1
fi
exit "$status"
