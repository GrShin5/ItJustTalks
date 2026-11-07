#!/bin/bash
# Offline tests: all security calls are intercepted; installation stops before build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat >"$WORK/bin/security" <<'FAKE'
#!/bin/bash
case "$1" in
 find-identity)
   [[ $STATE != inaccessible ]] || exit 1
   case "$STATE" in found|found-with-old|identity-duplicate) echo '1) 0000000000000000000000000000000000000000 "ItJustTalks Dev"';; esac
   [[ $STATE != identity-duplicate ]] || echo '2) 1111111111111111111111111111111111111111 "ItJustTalks Dev"'
   ;;
 find-certificate)
   case "$STATE" in
     absent) exit 44;;
     zero) echo '    "labl"<blob>="ItJustTalks Dev extra"';;
     inaccessible|certificate-error) exit 1;;
     *) echo '    "labl"<blob>="ItJustTalks Dev"'
        [[ $STATE != duplicate && $STATE != found-with-old ]] || echo '    "labl"<blob>="ItJustTalks Dev"';;
   esac;;
 *) echo 'Forbidden security mutation' >&2; exit 99;;
esac
exit 0
FAKE
cat >"$WORK/bin/xcrun" <<'FAKE'
#!/bin/bash
case "$*" in *--show-sdk-version*) echo 27.0;; *-typecheck*) exit 0;; *) exit 99;; esac
FAKE
cat >"$WORK/bin/swift" <<'FAKE'
#!/bin/bash
echo 'Apple Swift version 6.4'
FAKE
cat >"$WORK/bin/xcode-select" <<'FAKE'
#!/bin/bash
echo /Library/Developer/CommandLineTools
FAKE
cat >"$WORK/bin/sw_vers" <<'FAKE'
#!/bin/bash
echo 27.0
FAKE
cat >"$WORK/bin/uname" <<'FAKE'
#!/bin/bash
echo Darwin
FAKE
cat >"$WORK/bin/df" <<'FAKE'
#!/bin/bash
echo 'Filesystem blocks used available'
echo 'fake 9999999 0 9999999'
FAKE
cat >"$WORK/bin/libressl" <<'FAKE'
#!/bin/bash
echo 'LibreSSL 3.3.6'
FAKE
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" ITJUSTTALKS_LANG=en
source "$ROOT/scripts/lib/install_checks.sh"
failed=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"
  else echo "FAIL: $1 (expected $3, got $2)"; failed=1; fi
}
for state in found found-with-old untrusted absent duplicate inaccessible certificate-error identity-duplicate zero; do
  export STATE="$state"
  expected="$state"
  case "$state" in found-with-old) expected=found;; certificate-error) expected=inaccessible;; identity-duplicate) expected=duplicate;; zero) expected=absent;; esac
  check "keychain $state" "$(itjusttalks_keychain_state)" "$expected"
done
check 'trust class precedes keychain' "$(itjusttalks_codesign_failure_class 'keychain CSSMERR_TP_NOT_TRUSTED')" trust-unavailable
check 'LibreSSL fallback' "$(itjusttalks_find_certificate_tool "$WORK/bin/libressl")" "$(printf 'libressl\t%s' "$WORK/bin/libressl")"
export STATE=absent
if [[ -e /Applications/ItJustTalks.app || -L /Applications/ItJustTalks.app ]]; then
  # install.sh stops earlier (exit 2) when an app is already installed; this case needs a Mac without one.
  echo "SKIP: install requires approval (/Applications/ItJustTalks.app exists on this Mac)"
else
  status=0
  bash "$ROOT/scripts/install.sh" >"$WORK/install.log" 2>&1 || status=$?
  check 'install requires approval' "$status" 3
fi
status=0
bash "$ROOT/scripts/preflight.sh" --quiet >"$WORK/preflight.log" 2>&1 || status=$?
check 'preflight status' "$status" 0
check 'one RESULT line' "$(awk '/^RESULT:/ {n++} END {print n+0}' "$WORK/preflight.log")" 1
check 'preflight final line' "$(tail -1 "$WORK/preflight.log")" 'RESULT: needs-signing-cert'
exit "$failed"
