#!/bin/bash
# Builds a release "HiveWarden.app" into ./build (ad-hoc signed, menu-bar only).
# The SwiftPM product is called ClaudeWorkers (internal code name); the bundle and its
# executable carry the public name.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="HiveWarden"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeWorkers"
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.hivewarden.app</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>$NAME uses automation to bring the Terminal or iTerm tab running an agent to the front.</string>
</dict></plist>
PLIST
# Sign with a stable identity if you have one (keeps macOS permissions across rebuilds):
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null
echo "Built: $APP"
echo "Run:   open \"$APP\""
