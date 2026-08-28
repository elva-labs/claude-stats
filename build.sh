#!/bin/bash
# Builds Claude Stats.app.
#
#   ./build.sh                          build, install to /Applications, launch
#   VERSION=1.2.0 ./build.sh            stamp a release version (default 0.0.0-dev)
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
#                                       real signature + hardened runtime
#                                       (default: ad-hoc, fine for local use)
#   SKIP_INSTALL=1 ./build.sh           stop after dist/ — what CI uses
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Stats"
BUNDLE_ID="com.elva-labs.claude-stats"
VERSION="${VERSION:-0.0.0-dev}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR="dist/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"

echo "==> Compiling"
# Universal, so one download serves Apple Silicon and Intel Macs alike. Each
# slice is built on its own and joined with lipo: `swift build --arch a --arch b`
# would do it in one go, but needs Xcode's xcbuild, which the Command Line Tools
# toolchain lacks — and contributors shouldn't need Xcode just to build.
SLICES=()
for ARCH in arm64 x86_64; do
    swift build -c release --disable-sandbox --triple "${ARCH}-apple-macosx"
    SLICES+=("$(swift build -c release --show-bin-path --triple "${ARCH}-apple-macosx")/ClaudeStats")
done

echo "==> Assembling bundle (v${VERSION})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS" "$BUILD_DIR/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$BUILD_DIR/Contents/MacOS/ClaudeStats"

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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc: enough for the machine that built it. Keychain access doesn't depend
    # on the signature — tokens are read via /usr/bin/security (see Keychain.swift).
    codesign --force --sign - --identifier "$BUNDLE_ID" "$BUILD_DIR"
else
    # Hardened runtime and a timestamp are what notarization requires; the app
    # needs no entitlements (not sandboxed, no JIT).
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$BUILD_DIR"
fi

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
    echo "Done. Bundle at ${BUILD_DIR}"
    exit 0
fi

echo "==> Installing to ${INSTALL_DIR}"
pkill -x ClaudeStats 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR"
cp -R "$BUILD_DIR" "$INSTALL_DIR"

echo "==> Launching"
open "$INSTALL_DIR"
echo "Done. Look for the percentages in your menu bar."
