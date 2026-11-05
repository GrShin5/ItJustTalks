#!/usr/bin/env bash
# Build AFMBackgroundProbe and wrap it into an ad-hoc signed .app bundle.
# Output: .build/probe/AFMBackgroundProbe.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

APP_DIR=".build/probe"
APP="$APP_DIR/AFMBackgroundProbe.app"

swift build -c release --product AFMBackgroundProbe
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AFMBackgroundProbe" "$APP/Contents/MacOS/AFMBackgroundProbe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.itjusttalks.dev.afmprobe</string>
    <key>CFBundleName</key>
    <string>AFMBackgroundProbe</string>
    <key>CFBundleExecutable</key>
    <string>AFMBackgroundProbe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signing only (no certificate or keychain identity).
codesign --force --sign - "$APP"

echo "$ROOT/$APP"
