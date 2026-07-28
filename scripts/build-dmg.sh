#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DMG_BACKGROUND_SOURCE="$PROJECT_DIR/Resources/DMGBackground.svg"
DMG_LAYOUT_SCRIPT="$PROJECT_DIR/scripts/configure-dmg-layout.applescript"
DMG_LAYOUT_VERIFIER="$PROJECT_DIR/scripts/verify-dmg-layout.sh"
DMG_IMAGE_VERIFIER="$PROJECT_DIR/scripts/verify-dmg-image.sh"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-}"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    DMG_NAME="QuitHide-v${VERSION}-universal.dmg"
else
    DMG_NAME="QuitHide-v${VERSION}-universal-unsigned.dmg"
fi
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-release.XXXXXX")"
STAGING_DIR="${STAGING_DIR:A}"
SAFE_BUILD_DIR="$STAGING_DIR/build"
SOURCE_APP="$SAFE_BUILD_DIR/QuitHide.app"
DMG_CONTENTS_DIR="$STAGING_DIR/dmg"
DMG_BACKGROUND_DIR="$DMG_CONTENTS_DIR/.background"
DMG_BACKGROUND_PATH="$DMG_BACKGROUND_DIR/DMGBackground.png"
WRITABLE_DMG_PATH="$STAGING_DIR/QuitHide-layout.dmg"
MOUNT_DIR="$STAGING_DIR/mount"
DMG_IS_MOUNTED=0

cleanup() {
    if [[ "$DMG_IS_MOUNTED" == "1" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if ! MOUNTED_IMAGE_PATHS="$(
    /usr/bin/hdiutil info -plist |
        /usr/bin/python3 -c '
import plistlib
import sys

payload = plistlib.loads(sys.stdin.buffer.read())
for image in payload.get("images", []):
    for entity in image.get("system-entities", []):
        mount_point = entity.get("mount-point")
        if mount_point:
            print(mount_point)
'
)"; then
    /usr/bin/printf 'Could not inspect mounted disk images before building the DMG.\n' >&2
    exit 1
fi

CONFLICTING_MOUNTS=()
while IFS= read -r existing_mount; do
    [[ -n "$existing_mount" ]] || continue
    existing_volume_name="$(
        /usr/sbin/diskutil info -plist "$existing_mount" 2>/dev/null |
            /usr/bin/plutil -extract VolumeName raw -o - - 2>/dev/null || true
    )"
    if [[ "$existing_volume_name" == "QuitHide" ]]; then
        CONFLICTING_MOUNTS+=("$existing_mount")
    fi
done <<< "$MOUNTED_IMAGE_PATHS"
if (( ${#CONFLICTING_MOUNTS[@]} > 0 )); then
    /usr/bin/printf \
        'Cannot build the QuitHide DMG while another QuitHide disk image is mounted:\n' >&2
    for existing_mount in "${CONFLICTING_MOUNTS[@]}"; do
        /usr/bin/printf '  %s\n' "$existing_mount" >&2
    done
    /usr/bin/printf \
        'Eject the listed disk images and retry so Finder cannot write layout metadata to the wrong volume.\n' >&2
    exit 1
fi

QUITHIDE_OUTPUT_DIR="$SAFE_BUILD_DIR" "$PROJECT_DIR/scripts/build-app.sh"

/bin/mkdir -p "$DMG_BACKGROUND_DIR"
/usr/bin/ditto --norsrc "$SOURCE_APP" "$DMG_CONTENTS_DIR/QuitHide.app"
/bin/ln -s /Applications "$DMG_CONTENTS_DIR/Applications"
/usr/bin/sips \
    -s format png \
    "$DMG_BACKGROUND_SOURCE" \
    --out "$DMG_BACKGROUND_PATH" >/dev/null

BACKGROUND_WIDTH="$(/usr/bin/sips -g pixelWidth "$DMG_BACKGROUND_PATH" | /usr/bin/awk '/pixelWidth/ {print $2}')"
BACKGROUND_HEIGHT="$(/usr/bin/sips -g pixelHeight "$DMG_BACKGROUND_PATH" | /usr/bin/awk '/pixelHeight/ {print $2}')"
if [[ "$BACKGROUND_WIDTH" != "660" || "$BACKGROUND_HEIGHT" != "420" ]]; then
    /usr/bin/printf \
        'Unexpected DMG background dimensions: %sx%s (expected 660x420).\n' \
        "$BACKGROUND_WIDTH" \
        "$BACKGROUND_HEIGHT" >&2
    exit 1
fi

/usr/bin/xattr -cr "$DMG_CONTENTS_DIR/QuitHide.app"
/usr/bin/codesign --verify --deep --strict "$DMG_CONTENTS_DIR/QuitHide.app"
/usr/bin/lipo "$DMG_CONTENTS_DIR/QuitHide.app/Contents/MacOS/QuitHide" -verify_arch arm64
/usr/bin/lipo "$DMG_CONTENTS_DIR/QuitHide.app/Contents/MacOS/QuitHide" -verify_arch x86_64

/bin/mkdir -p "$DIST_DIR"
if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" ]]; then
    if [[ "${QUITHIDE_OVERWRITE_ARTIFACTS:-0}" != "1" ]]; then
        /usr/bin/printf 'Refusing to overwrite an existing DMG artifact: %s\n' "$DMG_PATH" >&2
        /usr/bin/printf 'Set QUITHIDE_OVERWRITE_ARTIFACTS=1 only for an intentional local rebuild.\n' >&2
        exit 1
    fi
    /bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH"
fi

/usr/bin/hdiutil create \
    -volname "QuitHide" \
    -srcfolder "$DMG_CONTENTS_DIR" \
    -ov \
    -format UDRW \
    "$WRITABLE_DMG_PATH" >/dev/null

/bin/mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach \
    "$WRITABLE_DMG_PATH" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null
DMG_IS_MOUNTED=1

/usr/bin/osascript "$DMG_LAYOUT_SCRIPT" "$MOUNT_DIR"

LAYOUT_STABLE_PASSES=0
LAYOUT_IS_STABLE=0
for attempt in {1..20}; do
    /bin/sync
    if "$DMG_LAYOUT_VERIFIER" "$MOUNT_DIR" "$VERSION" "$BUILD" >/dev/null 2>&1; then
        (( LAYOUT_STABLE_PASSES += 1 ))
    else
        LAYOUT_STABLE_PASSES=0
    fi
    if (( LAYOUT_STABLE_PASSES >= 2 )); then
        LAYOUT_IS_STABLE=1
        break
    fi
    /bin/sleep 0.5
done
if [[ "$LAYOUT_IS_STABLE" != "1" ]]; then
    "$DMG_LAYOUT_VERIFIER" "$MOUNT_DIR" "$VERSION" "$BUILD" || true
    /usr/bin/printf \
        'Finder DMG layout metadata did not become complete and stable before timeout.\n' >&2
    exit 1
fi

/usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null
DMG_IS_MOUNTED=0

/usr/bin/hdiutil convert \
    "$WRITABLE_DMG_PATH" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_PATH"
    /usr/bin/codesign --verify --strict "$DMG_PATH"
fi

"$DMG_IMAGE_VERIFIER" "$DMG_PATH" "$VERSION" "$BUILD"

cd "$DIST_DIR"
/usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"

/usr/bin/printf 'Built: %s\n' "$DMG_PATH"
/usr/bin/printf 'SHA-256: '
/usr/bin/awk '{print $1}' "$CHECKSUM_PATH"
