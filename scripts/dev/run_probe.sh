#!/usr/bin/env bash
# Run the AFMBackgroundProbe app in the background without activating it.
# Usage: scripts/dev/run_probe.sh <probe args...> --out <dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/.build/probe/AFMBackgroundProbe.app"

if [[ ! -d "$APP" ]]; then
    echo "Probe app not found. Run scripts/dev/make_probe_app.sh first." >&2
    exit 1
fi

OUT=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--out" && $((i + 1)) -lt ${#args[@]} ]]; then
        OUT="${args[$((i + 1))]}"
    fi
done
if [[ -z "$OUT" ]]; then
    echo "--out <dir> is required" >&2
    exit 2
fi
mkdir -p "$OUT"
# Make --out absolute so the app resolves it regardless of its working directory.
OUT="$(cd "$OUT" && pwd)"
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--out" ]]; then
        args[$((i + 1))]="$OUT"
    fi
done

# -g: do not bring to foreground, -n: new instance, -W: wait until the app exits.
caffeinate -i open -g -n -W "$APP" --args "${args[@]}"

echo "$OUT/summary.json"
