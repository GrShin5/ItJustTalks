#!/bin/zsh
# Run --test-regressions with Koedex data, ~/.codex and remote network denied.
# Usage: scripts/dev/run_regressions_sandboxed.sh [extra args, e.g. --max-skips 13]
set -euo pipefail
cd "${0:A:h}/../.."
bin=".build/debug/ItJustTalks"
[[ -x "$bin" ]] || { print -u2 "build first: swift build"; exit 2; }
# Self-check: the profile must block Koedex storage before running anything.
probe="$HOME/Library/Application Support/Koedex"
if [[ -e "$probe" ]] && sandbox-exec -D HOME="$HOME" -f scripts/dev/koedex-deny.sb /bin/ls "$probe" >/dev/null 2>&1; then
  print -u2 "sandbox self-check failed: Koedex storage is readable"; exit 3
fi
exec sandbox-exec -D HOME="$HOME" -f scripts/dev/koedex-deny.sb "$bin" --test-regressions "$@"
