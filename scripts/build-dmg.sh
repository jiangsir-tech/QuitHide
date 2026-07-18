#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"
SOURCE_APP="$DIST_DIR/QuitHide.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-}"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    DMG_NAME="QuitHide-v${VERSION}-universal.dmg"
else
    DMG_NAME="QuitHide-v${VERSION}-universal-unsigned.dmg"
fi
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-release.XXXXXX")"

cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$PROJECT_DIR/scripts/build-app.sh"

/bin/mkdir -p "$STAGING_DIR/dmg"
/usr/bin/ditto --norsrc "$SOURCE_APP" "$STAGING_DIR/dmg/QuitHide.app"
/bin/ln -s /Applications "$STAGING_DIR/dmg/Applications"

/usr/bin/xattr -cr "$STAGING_DIR/dmg/QuitHide.app"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/dmg/QuitHide.app"
/usr/bin/lipo "$STAGING_DIR/dmg/QuitHide.app/Contents/MacOS/QuitHide" -verify_arch arm64 x86_64

/bin/mkdir -p "$DIST_DIR"
/bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH"
/usr/bin/hdiutil create \
    -volname "QuitHide" \
    -srcfolder "$STAGING_DIR/dmg" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_PATH"
    /usr/bin/codesign --verify --strict "$DMG_PATH"
fi

cd "$DIST_DIR"
/usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"

/usr/bin/printf 'Built: %s\n' "$DMG_PATH"
/usr/bin/printf 'SHA-256: '
/usr/bin/awk '{print $1}' "$CHECKSUM_PATH"
