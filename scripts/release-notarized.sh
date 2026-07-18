#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$DIST_DIR/QuitHide-v${VERSION}-universal.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-Developer ID Application: Yongjiang Li (93GC94J9B6)}"
NOTARY_PROFILE="${QUITHIDE_NOTARY_PROFILE:-QuitHide-notary}"

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
    /usr/bin/printf 'No valid signing identity found: %s\n' "$SIGNING_IDENTITY" >&2
    exit 1
fi

# This authenticates the keychain profile without exposing its stored password.
/usr/bin/xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null

QUITHIDE_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$PROJECT_DIR/scripts/build-dmg.sh"

/usr/bin/xcrun notarytool submit \
    "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"
/usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$DMG_PATH"

cd "$DIST_DIR"
/usr/bin/shasum -a 256 "${DMG_PATH:t}" > "${CHECKSUM_PATH:t}"

/usr/bin/printf 'Notarized release: %s\n' "$DMG_PATH"
/usr/bin/printf 'SHA-256: '
/usr/bin/awk '{print $1}' "$CHECKSUM_PATH"
