#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/QuitHide.app"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-}"
ASSEMBLY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-app.XXXXXX")"
STAGED_APP="$ASSEMBLY_DIR/QuitHide.app"

cleanup() {
    /bin/rm -rf "$ASSEMBLY_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
/usr/bin/xcrun swift build -c release --arch arm64 --scratch-path "$PROJECT_DIR/.build/arm64"
/usr/bin/xcrun swift build -c release --arch x86_64 --scratch-path "$PROJECT_DIR/.build/x86_64"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/lipo -create \
    ".build/arm64/arm64-apple-macosx/release/QuitHide" \
    ".build/x86_64/x86_64-apple-macosx/release/QuitHide" \
    -output "$STAGED_APP/Contents/MacOS/QuitHide"
/bin/cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/QuitHide"
/usr/bin/xattr -cr "$STAGED_APP"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$STAGED_APP"
else
    /usr/bin/codesign --force --sign - "$STAGED_APP"
fi
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# Assemble and sign outside Documents so File Provider metadata cannot poison
# the signature. Copy back without resource forks only after verification.
/bin/rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$STAGED_APP" "$APP_DIR"
/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/QuitHide"

/usr/bin/printf 'Built: %s\n' "$APP_DIR"
