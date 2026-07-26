#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${QUITHIDE_OUTPUT_DIR:-$PROJECT_DIR/dist}"
APP_DIR="$OUTPUT_DIR/QuitHide.app"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-}"
LOCALIZATION_DIR="$PROJECT_DIR/Sources/QuitHide/Resources"
LOCALIZATION_VERIFIER="$PROJECT_DIR/scripts/verify-localizations.sh"
SPARKLE_VERIFIER="$PROJECT_DIR/scripts/verify-sparkle-bundle.sh"
ASSEMBLY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-app.XXXXXX")"
STAGED_APP="$ASSEMBLY_DIR/QuitHide.app"
ARM64_SCRATCH="$PROJECT_DIR/.build/arm64"
X86_64_SCRATCH="$PROJECT_DIR/.build/x86_64"
SWIFT_APP_FLAGS=(
    -Xswiftc -DQUITHIDE_APP_BUNDLE
    -Xlinker -rpath
    -Xlinker @loader_path/../Frameworks
)

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

# SwiftPM resolves Sparkle as a binary XCFramework. Copy the complete framework
# rather than only its dylib: the updater, installer, resources, and symlinks are
# all part of Sparkle's supported distribution layout.
SPARKLE_FRAMEWORK_CANDIDATES=(
    "$ARM64_SCRATCH"/artifacts/**/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework(N)
)
if (( ${#SPARKLE_FRAMEWORK_CANDIDATES[@]} != 1 )); then
    /usr/bin/printf \
        'Expected exactly one resolved Sparkle.framework in %s/artifacts; found %d.\n' \
        "$ARM64_SCRATCH" \
        "${#SPARKLE_FRAMEWORK_CANDIDATES[@]}" >&2
    exit 1
fi
SPARKLE_FRAMEWORK_SOURCE="${SPARKLE_FRAMEWORK_CANDIDATES[1]}"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/mkdir -p \
    "$STAGED_APP/Contents/MacOS" \
    "$STAGED_APP/Contents/Resources" \
    "$STAGED_APP/Contents/Frameworks"
/usr/bin/lipo -create \
    "$ARM64_BIN_DIR/QuitHide" \
    "$X86_64_BIN_DIR/QuitHide" \
    -output "$STAGED_APP/Contents/MacOS/QuitHide"
/bin/cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto --norsrc \
    "$SPARKLE_FRAMEWORK_SOURCE" \
    "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
for localization in "$LOCALIZATION_DIR"/*.lproj(N); do
    /usr/bin/ditto --norsrc \
        "$localization" \
        "$STAGED_APP/Contents/Resources/${localization:t}"
done
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/QuitHide"
"$LOCALIZATION_VERIFIER" --app "$STAGED_APP" --check-architectures
/usr/bin/xattr -cr "$STAGED_APP"

SPARKLE_FRAMEWORK="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
SPARKLE_NESTED_CODE=(
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
    "$SPARKLE_VERSION_DIR/Autoupdate"
    "$SPARKLE_VERSION_DIR/Updater.app"
)

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # Sparkle's binary distribution is ad-hoc signed. For Developer ID builds,
    # re-sign every nested component from the inside out before the framework
    # and host app. Do not use --deep for signing.
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "${SPARKLE_NESTED_CODE[1]}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --preserve-metadata=entitlements \
        --sign "$SIGNING_IDENTITY" \
        "${SPARKLE_NESTED_CODE[2]}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "${SPARKLE_NESTED_CODE[3]}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "${SPARKLE_NESTED_CODE[4]}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$SPARKLE_FRAMEWORK"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$STAGED_APP"
else
    /usr/bin/codesign --force --sign - "${SPARKLE_NESTED_CODE[1]}"
    /usr/bin/codesign \
        --force \
        --preserve-metadata=entitlements \
        --sign - \
        "${SPARKLE_NESTED_CODE[2]}"
    /usr/bin/codesign --force --sign - "${SPARKLE_NESTED_CODE[3]}"
    /usr/bin/codesign --force --sign - "${SPARKLE_NESTED_CODE[4]}"
    /usr/bin/codesign --force --sign - "$SPARKLE_FRAMEWORK"
    /usr/bin/codesign --force --sign - "$STAGED_APP"
fi
"$LOCALIZATION_VERIFIER" --app "$STAGED_APP" --check-signature --check-architectures
"$SPARKLE_VERIFIER" "$STAGED_APP"

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
"$SPARKLE_VERIFIER" "$APP_DIR"

/usr/bin/printf 'Built: %s\n' "$APP_DIR"
