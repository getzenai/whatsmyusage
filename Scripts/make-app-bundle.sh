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
#
# Releases set it to the Developer ID Application certificate, which is what
# notarisation needs. Everything else about the bundle is the same either way.
set -euo pipefail

CONFIGURATION="${1:-release}"
# Keep in sync with Sources/UsageBarApp/AppIdentity.swift
BUNDLE_ID="com.whatsmyusage.app"
APP_NAME="WhatsMyUsage"
PRODUCT_NAME="UsageBar"
ICON_NAME="AppIcon"
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# The latest v<x.y.z> tag is the version; there is no second copy of it to go
# stale. A build made after the tag still says the tag's version — CFBundleVersion
# below carries the commit, which is what tells two builds apart.
VERSION="$(python3 Scripts/semver.py current)"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD -- 2>/dev/null; then
    BUILD="${BUILD}-dirty"
fi

echo "==> Building $PRODUCT_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
echo "==> Building whatsmyusage ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product whatsmyusage

BIN_PATH="$(swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME" --show-bin-path)"
CLI_BIN_PATH="$(swift build -c "$CONFIGURATION" --product whatsmyusage --show-bin-path)"
APP_PATH="$REPO_ROOT/.build/$APP_NAME.app"

# Copy SRC onto DEST. If DEST already exists it must be the file this script
# expects to update: a regular file whose on-disk name matches DEST exactly.
# A case-folded hit (WhatsMyUsage vs whatsmyusage on APFS) is not that file —
# it is a different product sitting on the same path, and overwriting it is
# how this script once replaced the menu-bar app with the CLI.
install_file() {
    local src="$1" dest="$2"
    local dest_dir dest_base
    dest_dir=$(dirname -- "$dest")
    dest_base=$(basename -- "$dest")

    if [[ ! -f "$src" ]]; then
        echo "error: source is not a regular file: $src" >&2
        exit 1
    fi

    mkdir -p "$dest_dir"

    if [[ -e "$dest" || -L "$dest" ]]; then
        if [[ -d "$dest" && ! -L "$dest" ]]; then
            echo "error: refusing to overwrite directory: $dest" >&2
            exit 1
        fi
        if ! python3 -c 'import os, sys; raise SystemExit(0 if sys.argv[2] in os.listdir(sys.argv[1]) else 1)' \
            "$dest_dir" "$dest_base"; then
            python3 -c '
import os, sys
directory, name = sys.argv[1], sys.argv[2]
print(f"error: {os.path.join(directory, name)} already exists under a different name; refusing to overwrite", file=sys.stderr)
for entry in os.listdir(directory):
    if entry.lower() == name.lower():
        print(f"error: existing entry is {entry!r}", file=sys.stderr)
' "$dest_dir" "$dest_base"
            exit 1
        fi
    fi

    cp "$src" "$dest"
    if ! cmp -s "$src" "$dest"; then
        echo "error: copy did not land as written: $dest" >&2
        exit 1
    fi
}

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
# The CLI is not a bundle citizen. Agents call ~/.local/bin/whatsmyusage; the
# app never launches it. Shipping it next to WhatsMyUsage is how a case-fold
# collision replaced the menu-bar binary with --help.
install_file "$BIN_PATH/$PRODUCT_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
# Committed, not built here: see Scripts/make-icon.swift. Without an icon the
# app shows the blank sheet in Login Items and in every notification it posts.
install_file "$REPO_ROOT/Resources/$ICON_NAME.icns" "$APP_PATH/Contents/Resources/$ICON_NAME.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>
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
# Hardened runtime always: notarisation rejects a bundle without it, and a
# local build that skips it would not be the thing the release job ships.
SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # Apple's timestamp server has nothing to countersign for an ad-hoc
    # signature; asking anyway fails the build.
    SIGN_ARGS+=(--timestamp=none)
else
    # A real timestamp, not --timestamp=none: without it the signature dies
    # with the certificate in 2031 instead of outliving it.
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_PATH"
codesign --verify --verbose=2 "$APP_PATH"
codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^.*designated => /designated => /p'

# Copy the CLI onto PATH so agents can run `whatsmyusage status --json`
# without a path. ~/.local/bin is user-writable and already on Fabian's
# PATH; no sudo, no second Keychain identity. Not copied into the bundle:
# nothing in the app launches it, and a second product in MacOS/ is how
# the last build overwrote the menu-bar binary on a case-insensitive volume.
CLI_PATH="${HOME}/.local/bin"
if [[ -n "${USAGE_BAR_SKIP_CLI_INSTALL:-}" ]]; then
    echo "==> Skipping CLI install (USAGE_BAR_SKIP_CLI_INSTALL set)"
else
    install_file "$CLI_BIN_PATH/whatsmyusage" "$CLI_PATH/whatsmyusage"
    chmod +x "$CLI_PATH/whatsmyusage"
fi

echo
echo "Built $APP_PATH ($VERSION · $BUILD)"
if [[ -z "${USAGE_BAR_SKIP_CLI_INSTALL:-}" ]]; then
    echo "CLI: $CLI_PATH/whatsmyusage"
fi
echo "Run it with:  open \"$APP_PATH\""
