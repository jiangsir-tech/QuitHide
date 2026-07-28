#!/bin/zsh
set -euo pipefail

MOUNT_DIR="${1:-}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"

fail() {
    /usr/bin/printf 'Invalid DMG layout: %s\n' "$1" >&2
    exit 1
}

if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    fail "mounted volume directory is missing"
fi
if [[ -n "$EXPECTED_VERSION" && -z "$EXPECTED_BUILD" ]] || \
    [[ -z "$EXPECTED_VERSION" && -n "$EXPECTED_BUILD" ]]; then
    fail "expected version and build must be provided together"
fi

DS_STORE_PATH="$MOUNT_DIR/.DS_Store"
BACKGROUND_PATH="$MOUNT_DIR/.background/DMGBackground.png"
APPLICATIONS_LINK="$MOUNT_DIR/Applications"
APP_PATH="$MOUNT_DIR/QuitHide.app"

if [[ ! -f "$DS_STORE_PATH" ]]; then
    fail ".DS_Store is missing"
fi
DS_STORE_SIZE="$(/usr/bin/stat -f '%z' "$DS_STORE_PATH")"
if (( DS_STORE_SIZE < 1024 )); then
    fail ".DS_Store is too small (${DS_STORE_SIZE} bytes)"
fi

DS_STORE_STRINGS="$(/usr/bin/strings -a "$DS_STORE_PATH")"
for required_marker in \
    '.bwspblob' \
    '.icvpblob' \
    'backgroundImageAlias' \
    'DMGBackground.png' \
    '.background' \
    'pIlocblob' \
    'sIlocblob'; do
    if [[ "$DS_STORE_STRINGS" != *"$required_marker"* ]]; then
        fail ".DS_Store does not contain Finder layout marker: $required_marker"
    fi
done

if [[ ! -f "$BACKGROUND_PATH" ]]; then
    fail "background image is missing"
fi
BACKGROUND_WIDTH="$(/usr/bin/sips -g pixelWidth "$BACKGROUND_PATH" | /usr/bin/awk '/pixelWidth/ {print $2}')"
BACKGROUND_HEIGHT="$(/usr/bin/sips -g pixelHeight "$BACKGROUND_PATH" | /usr/bin/awk '/pixelHeight/ {print $2}')"
if [[ "$BACKGROUND_WIDTH" != "660" || "$BACKGROUND_HEIGHT" != "420" ]]; then
    fail "background image is ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}, expected 660x420"
fi

if [[ ! -L "$APPLICATIONS_LINK" ]]; then
    fail "Applications link is missing"
fi
if [[ "$(/usr/bin/readlink "$APPLICATIONS_LINK")" != "/Applications" ]]; then
    fail "Applications link does not point to /Applications"
fi
if [[ ! -d "$APP_PATH" ]]; then
    fail "QuitHide.app is missing"
fi

if [[ -n "$EXPECTED_VERSION" ]]; then
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    BINARY_PATH="$APP_PATH/Contents/MacOS/QuitHide"
    if [[ ! -f "$INFO_PLIST" || ! -f "$BINARY_PATH" ]]; then
        fail "QuitHide.app bundle is incomplete"
    fi

    ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
    ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
    if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" || "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
        fail "app version is ${ACTUAL_VERSION} (${ACTUAL_BUILD}), expected ${EXPECTED_VERSION} (${EXPECTED_BUILD})"
    fi

    /usr/bin/lipo "$BINARY_PATH" -verify_arch arm64
    /usr/bin/lipo "$BINARY_PATH" -verify_arch x86_64
    /usr/bin/codesign --verify --deep --strict "$APP_PATH"
fi

/usr/bin/printf \
    'Verified DMG layout: .DS_Store %s bytes, background %sx%s\n' \
    "$DS_STORE_SIZE" \
    "$BACKGROUND_WIDTH" \
    "$BACKGROUND_HEIGHT"
