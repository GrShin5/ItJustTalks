#!/bin/bash
# Parent-run Swift Testing harness; isolates tool contracts from the app target.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_PACKAGE="$(mktemp -d "${TMPDIR:-/tmp}/afm-contracts.XXXXXX")"
trap 'rm -rf "$TEMP_PACKAGE"' EXIT
mkdir -p "$TEMP_PACKAGE/Sources" "$TEMP_PACKAGE/Tests"
cp -R "$ROOT/Sources/ItJustTalksAI" "$TEMP_PACKAGE/Sources/"
FILES=(Cases Judge Records Options CancelRecovery RunManifest Rescore)
for file in "${FILES[@]}"; do
  cp "$ROOT/Tools/afm-eval/$file.swift" "$TEMP_PACKAGE/Tests/"
done
cp "$ROOT/Evaluation/tests/AFMEvalContractTests.swift" "$TEMP_PACKAGE/Tests/"
cat > "$TEMP_PACKAGE/Package.swift" <<'PACKAGE'
// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "EvalContracts", platforms: [.macOS(.v27)], targets: [
    .target(name: "ItJustTalksAI"),
    .testTarget(name: "EvalContractsTests", dependencies: ["ItJustTalksAI"], path: "Tests")
])
PACKAGE
AFM_CONTRACT_CASES="$ROOT/Evaluation/accuracy" AFM_CONTRACT_OPTIMIZATION="$ROOT/Evaluation/cases" \
swift test --package-path "$TEMP_PACKAGE" "$@"
