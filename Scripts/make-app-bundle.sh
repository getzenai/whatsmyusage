#!/bin/bash
# Assembles "WhatsMyUsage.app" from the SwiftPM executable.
#
# There is no Xcode project on purpose: SwiftPM produces a bare Mach-O binary,
# and a menu bar app needs a real .app bundle for LSUIElement (no Dock icon).
#
# Usage: Scripts/make-app-bundle.sh [debug|release]   (default: release)
#
# Sign with USAGE_BAR_SIGN_IDENTITY when set. Unset means ad-hoc (`-`): the
# identity is the binary hash, so Keychain treats every rebuild as a new app.
# See README for making a local code-signing certificate in two minutes.
set -euo pipefail

CONFIGURATION="${1:-release}"
# Keep in sync with Sources/UsageBarApp/AppIdentity.swift
BUNDLE_ID="com.whatsmyusage.app"
APP_NAME="WhatsMyUsage"
PRODUCT_NAME="UsageBar"
VERSION="0.1.0"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD -- 2>/dev/null; then
    BUILD="${BUILD}-dirty"
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

echo "==> Building $PRODUCT_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
echo "==> Building whatsmyusage ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product whatsmyusage

BIN_PATH="$(swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME" --show-bin-path)"
CLI_BIN_PATH="$(swift build -c "$CONFIGURATION" --product whatsmyusage --show-bin-path)"
APP_PATH="$REPO_ROOT/.build/$APP_NAME.app"

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/$PRODUCT_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$CLI_BIN_PATH/whatsmyusage" "$APP_PATH/Contents/MacOS/whatsmyusage"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${USAGE_BAR_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_PATH"
codesign --verify --verbose=2 "$APP_PATH"
codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^.*designated => /designated => /p'

# Copy the signed CLI onto PATH so agents can run `whatsmyusage status --json`
# without knowing the bundle. ~/.local/bin is user-writable and already on
# Fabian's PATH; no sudo, no second Keychain identity.
CLI_PATH="${HOME}/.local/bin"
mkdir -p "$CLI_PATH"
cp "$APP_PATH/Contents/MacOS/whatsmyusage" "$CLI_PATH/whatsmyusage"
chmod +x "$CLI_PATH/whatsmyusage"

echo
echo "Built $APP_PATH ($VERSION · $BUILD)"
echo "CLI: $CLI_PATH/whatsmyusage"
echo "Run it with:  open \"$APP_PATH\""
