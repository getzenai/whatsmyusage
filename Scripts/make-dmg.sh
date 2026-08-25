#!/bin/bash
# Wraps WhatsMyUsage.app in the disk image people download.
#
# Why a disk image at all, when Sparkle updates from a zip: the zip is the
# update format, this is the install format. A .dmg opens into a window with
# the app on the left and an Applications alias on the right, which is how a
# Mac user has installed software for twenty years — and it makes the one step
# that matters obvious. An app left in ~/Downloads runs from a read-only random
# path (App Translocation) and can never update itself; dragging it out is the
# fix, so the window should ask for it.
#
# Usage: Scripts/make-dmg.sh [path/to/WhatsMyUsage.app]   (default: .build/…)
#
# Needs dmgbuild and pillow; see docs/UPDATES.md. Signs the image with
# USAGE_BAR_SIGN_IDENTITY when set. An unsigned image is fine for looking at
# locally and useless for shipping: Gatekeeper checks the image as well as the
# app inside it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-.build/WhatsMyUsage.app}"
OUT=".build/WhatsMyUsage.dmg"
# The volume name is what the window is titled. Override it when testing by
# hand: Finder remembers a window per volume name, so two probes in a row show
# you the first one's settings.
VOLUME_NAME="${USAGE_BAR_DMG_VOLUME:-WhatsMyUsage}"

[ -d "$APP" ] || { echo "error: no app bundle at $APP" >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
cleanup() {
    if [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# One picture at 1x and 2x, joined into the multi-representation TIFF the
# Finder wants. Handed a single PNG it scales, and the arrow goes soft.
python3 Scripts/dmg_background.py "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$WORK/background.tiff" > /dev/null

dmgbuild -s Scripts/dmg-settings.py \
    -D app_path="$PWD/$APP" \
    -D background_path="$WORK/background.tiff" \
    -D volume_name="$VOLUME_NAME" \
    "$VOLUME_NAME" "$WORK/staged.dmg"

# Read-only and compressed on the way out, writable in between: the window
# settings need one correction that can only be made on a mounted volume.
# See Scripts/dmg_drop_stale_bookmark.py for what and why.
hdiutil convert "$WORK/staged.dmg" -format UDRW -o "$WORK/rw.dmg" -quiet
hdiutil attach "$WORK/rw.dmg" -nobrowse -mountpoint "$MOUNT" -quiet
python3 Scripts/dmg_drop_stale_bookmark.py "$MOUNT"
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -o "$OUT" -quiet

# Read back what was actually produced. A disk image with the right files in
# it still opens as a blank window if the settings are wrong, and nothing in
# the build says so.
hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
python3 Scripts/dmg_check_window.py "$MOUNT"
hdiutil detach "$MOUNT" -quiet

if [ -n "${USAGE_BAR_SIGN_IDENTITY:-}" ]; then
    codesign --sign "$USAGE_BAR_SIGN_IDENTITY" --timestamp "$OUT"
    codesign --verify --verbose=2 "$OUT"
else
    echo "note: USAGE_BAR_SIGN_IDENTITY unset — the image is unsigned"
fi

echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
