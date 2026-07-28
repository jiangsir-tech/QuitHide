#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DMG_PATH="${1:-}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"

if [[ -z "$DMG_PATH" || -z "$EXPECTED_VERSION" || -z "$EXPECTED_BUILD" ]]; then
    /usr/bin/printf \
        'Usage: %s <dmg-path> <expected-version> <expected-build>\n' \
        "${0:t}" >&2
    exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
    /usr/bin/printf 'DMG does not exist: %s\n' "$DMG_PATH" >&2
    exit 1
fi

VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-dmg-verify.XXXXXX")"
MOUNT_DIR="$VERIFY_DIR/mount"
DMG_IS_MOUNTED=0

cleanup() {
    if [[ "$DMG_IS_MOUNTED" == "1" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

/bin/mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach \
    "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null
DMG_IS_MOUNTED=1

"$PROJECT_DIR/scripts/verify-dmg-layout.sh" \
    "$MOUNT_DIR" \
    "$EXPECTED_VERSION" \
    "$EXPECTED_BUILD"

/usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null
DMG_IS_MOUNTED=0

/usr/bin/printf 'Verified final DMG image: %s\n' "$DMG_PATH"
