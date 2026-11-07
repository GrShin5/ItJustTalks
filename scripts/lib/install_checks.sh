#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
# Shared, read-only probes for the local installation scripts.

itjusttalks_keychain_state() {
  local output status identities certificates
  if output="$(security find-identity -v -p codesigning 2>&1)"; then status=0; else status=$?; fi
  [[ $status -eq 0 ]] || { echo inaccessible; return; }
  identities="$(printf '%s\n' "$output" | awk '/"ItJustTalks Dev"/ {n++} END {print n+0}')"
  if output="$(security find-certificate -a -c "ItJustTalks Dev" "$HOME/Library/Keychains/login.keychain-db" 2>&1)"; then status=0; else status=$?; fi
  [[ $status -eq 0 || $status -eq 44 ]] || { echo inaccessible; return; }
  certificates="$(printf '%s\n' "$output" | awk '/"labl"<blob>="ItJustTalks Dev"$/ {n++} END {print n+0}')"
  # One valid identity is usable even if an old same-name certificate remains (0.1.0 behaviour).
  # Duplicate means no single identity can be chosen: never create another in that state.
  if [[ $identities -ge 2 || ( $identities -eq 0 && $certificates -ge 2 ) ]]; then echo duplicate
  elif [[ $identities -eq 1 ]]; then echo found
  elif [[ $status -eq 44 || $certificates -eq 0 ]]; then echo absent
  else echo untrusted; fi
}

itjusttalks_openssl3_candidates() {
  local path_candidate brew_prefix candidate seen=""
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
    return 0
  fi
  path_candidate="$(command -v openssl 2>/dev/null || true)"
  brew_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
  for candidate in "$path_candidate" "${brew_prefix:+$brew_prefix/bin/openssl}" \
    /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    candidate="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
    case "|${seen:-}|" in *"|$candidate|"*) continue ;; esac
    seen="${seen:-}|$candidate"
    printf '%s\n' "$candidate"
  done
}

itjusttalks_find_openssl3() {
  local candidate version
  while IFS= read -r candidate; do
    version="$("$candidate" version 2>&1 || true)"
    if [[ "$version" == OpenSSL\ 3* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(itjusttalks_openssl3_candidates "$@")
  return 1
}

itjusttalks_install_target_exists() {
  [[ "$#" -eq 1 ]] || return 2
  [[ -e "$1" || -L "$1" ]]
}

itjusttalks_codesign_failure_class() {
  local text="$1"
  if [[ "$text" == *CSSMERR_TP_NOT_TRUSTED* ]]; then
    printf '%s\n' trust-unavailable
  elif [[ "$text" == *"User interaction is not allowed"* || "$text" == *"keychain"* || "$text" == *"Keychain"* ]]; then
    printf '%s\n' keychain-inaccessible
  elif [[ "$text" == *"code object is not signed at all"* || "$text" == *"invalid signature"* || "$text" == *"a sealed resource is missing or invalid"* ]]; then
    printf '%s\n' signature-corrupt
  else
    printf '%s\n' signature-verification-failed
  fi
}


# Prints kind<TAB>path. Explicit candidates isolate tests; default fallback is macOS LibreSSL.
itjusttalks_find_certificate_tool() {
  local candidate version
  if candidate="$(itjusttalks_find_openssl3 "$@")"; then
    printf 'openssl3\t%s\n' "$candidate"; return 0
  fi
  if [[ $# -eq 0 ]]; then set -- /usr/bin/openssl; fi
  for candidate in "$@"; do
    version="$("$candidate" version 2>/dev/null || true)"
    if [[ "$version" == LibreSSL* ]]; then
      printf 'libressl\t%s\n' "$candidate"; return 0
    fi
  done
  return 1
}
