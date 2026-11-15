#!/bin/bash
# Builds a release "HiveWarden.app" into ./build (ad-hoc signed, Dock + menu-bar icon).
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

# App icon: assets/AppIcon.png (1024px, drawn by scripts/make-icon.swift) -> AppIcon.icns
ICON_SRC="assets/AppIcon.png"
[ -f "$ICON_SRC" ] || swift scripts/make-icon.swift "$ICON_SRC"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
