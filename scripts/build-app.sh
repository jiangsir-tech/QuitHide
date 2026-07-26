#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${QUITHIDE_OUTPUT_DIR:-$PROJECT_DIR/dist}"
APP_DIR="$OUTPUT_DIR/QuitHide.app"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-}"
LOCALIZATION_DIR="$PROJECT_DIR/Sources/QuitHide/Resources"
LOCALIZATION_VERIFIER="$PROJECT_DIR/scripts/verify-localizations.sh"
ASSEMBLY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-app.XXXXXX")"
STAGED_APP="$ASSEMBLY_DIR/QuitHide.app"
ARM64_SCRATCH="$PROJECT_DIR/.build/arm64"
X86_64_SCRATCH="$PROJECT_DIR/.build/x86_64"
SWIFT_APP_FLAGS=(-Xswiftc -DQUITHIDE_APP_BUNDLE)

cleanup() {
    /bin/rm -rf "$ASSEMBLY_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
"$LOCALIZATION_VERIFIER"
/usr/bin/xcrun swift build -c release --arch arm64 --scratch-path "$ARM64_SCRATCH" "${SWIFT_APP_FLAGS[@]}"
/usr/bin/xcrun swift build -c release --arch x86_64 --scratch-path "$X86_64_SCRATCH" "${SWIFT_APP_FLAGS[@]}"
ARM64_BIN_DIR="$(/usr/bin/xcrun swift build -c release --arch arm64 --scratch-path "$ARM64_SCRATCH" "${SWIFT_APP_FLAGS[@]}" --show-bin-path)"
X86_64_BIN_DIR="$(/usr/bin/xcrun swift build -c release --arch x86_64 --scratch-path "$X86_64_SCRATCH" "${SWIFT_APP_FLAGS[@]}" --show-bin-path)"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/lipo -create \
    "$ARM64_BIN_DIR/QuitHide" \
    "$X86_64_BIN_DIR/QuitHide" \
    -output "$STAGED_APP/Contents/MacOS/QuitHide"
/bin/cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
for localization in "$LOCALIZATION_DIR"/*.lproj(N); do
    /usr/bin/ditto --norsrc \
        "$localization" \
        "$STAGED_APP/Contents/Resources/${localization:t}"
done
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/QuitHide"
"$LOCALIZATION_VERIFIER" --app "$STAGED_APP" --check-architectures
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
"$LOCALIZATION_VERIFIER" --app "$STAGED_APP" --check-signature --check-architectures

# Assemble and sign outside Documents so File Provider metadata cannot poison
# the signature. Copy back without resource forks only after verification.
/bin/rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$STAGED_APP" "$APP_DIR"
/usr/bin/xattr -cr "$APP_DIR"
if ! /usr/bin/codesign --verify --deep --strict "$APP_DIR"; then
    /usr/bin/printf 'Final app signature was contaminated after copying to: %s\n' "$APP_DIR" >&2
    /usr/bin/printf 'Use QUITHIDE_OUTPUT_DIR on a non-File-Provider path, or build the DMG.\n' >&2
    /bin/rm -rf "$APP_DIR"
    exit 1
fi
# File Provider metadata can be attached just after ditto returns. Verify again
# after a short stabilization window so the script cannot report a transiently
# valid app that is already invalid by the time the caller uses it.
/bin/sleep 1
if ! /usr/bin/codesign --verify --deep --strict "$APP_DIR"; then
    /usr/bin/printf 'Final app signature became invalid after File Provider processing: %s\n' "$APP_DIR" >&2
    /usr/bin/printf 'Use QUITHIDE_OUTPUT_DIR on a non-File-Provider path, or build the DMG.\n' >&2
    /bin/rm -rf "$APP_DIR"
    exit 1
fi
/usr/bin/lipo "$APP_DIR/Contents/MacOS/QuitHide" -verify_arch arm64
/usr/bin/lipo "$APP_DIR/Contents/MacOS/QuitHide" -verify_arch x86_64
"$LOCALIZATION_VERIFIER" --app "$APP_DIR" --check-signature --check-architectures

/usr/bin/printf 'Built: %s\n' "$APP_DIR"
