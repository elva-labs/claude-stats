#!/bin/bash
# Builds Claude Stats.app and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Stats"
BUNDLE_ID="com.tobias.claudestats"
BUILD_DIR="dist/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"

echo "==> Compiling"
swift build -c release --disable-sandbox

echo "==> Assembling bundle"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS" "$BUILD_DIR/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ClaudeStats" "$BUILD_DIR/Contents/MacOS/ClaudeStats"

cat > "$BUILD_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>ClaudeStats</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps the bundle identity stable for this build, which is what
# the keychain ACL ("Always Allow") is remembered against.
codesign --force --sign - --identifier "$BUNDLE_ID" "$BUILD_DIR" >/dev/null 2>&1

echo "==> Installing to ${INSTALL_DIR}"
pkill -x ClaudeStats 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR"
cp -R "$BUILD_DIR" "$INSTALL_DIR"

echo "==> Launching"
open "$INSTALL_DIR"
echo "Done. Look for the percentages in your menu bar."
