#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
VERIFY_LAYOUT="$PROJECT_DIR/scripts/verify-dmg-layout.sh"
FIXTURE_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-dmg-layout-tests.XXXXXX")"

cleanup() {
    /bin/rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

/bin/mkdir -p "$FIXTURE_DIR/.background" "$FIXTURE_DIR/QuitHide.app"
/bin/ln -s /Applications "$FIXTURE_DIR/Applications"
/usr/bin/sips \
    -s format png \
    "$PROJECT_DIR/Resources/DMGBackground.svg" \
    --out "$FIXTURE_DIR/.background/DMGBackground.png" >/dev/null

/usr/bin/printf \
    'Bud1\n.bwspblob\n.icvpblob\nbackgroundImageAlias\nDMGBackground.png\n.background\npIlocblob\nsIlocblob\n' \
    > "$FIXTURE_DIR/.DS_Store"
/bin/dd if=/dev/zero bs=1024 count=4 >> "$FIXTURE_DIR/.DS_Store" 2>/dev/null

"$VERIFY_LAYOUT" "$FIXTURE_DIR" >/dev/null

/usr/bin/printf \
    'Bud1\n.bwspblob\n.icvpblob\nbackgroundImageAlias\nDMGBackground.png\n.background\npIlocblob\n' \
    > "$FIXTURE_DIR/.DS_Store"
/bin/dd if=/dev/zero bs=1024 count=4 >> "$FIXTURE_DIR/.DS_Store" 2>/dev/null
if "$VERIFY_LAYOUT" "$FIXTURE_DIR" >/dev/null 2>&1; then
    /usr/bin/printf 'FAIL: DMG layout verification accepted a missing icon position\n' >&2
    exit 1
fi

/bin/rm "$FIXTURE_DIR/.DS_Store"
if "$VERIFY_LAYOUT" "$FIXTURE_DIR" >/dev/null 2>&1; then
    /usr/bin/printf 'FAIL: DMG layout verification accepted a missing .DS_Store\n' >&2
    exit 1
fi

if ! /usr/bin/grep -Fq 'verify-dmg-image.sh' "$PROJECT_DIR/scripts/build-dmg.sh"; then
    /usr/bin/printf 'FAIL: build-dmg.sh does not verify the final DMG image\n' >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'verify-dmg-image.sh' "$PROJECT_DIR/scripts/release-notarized.sh"; then
    /usr/bin/printf 'FAIL: release-notarized.sh does not verify the stapled DMG image\n' >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'verify-dmg-image.sh' "$PROJECT_DIR/scripts/publish-release.sh"; then
    /usr/bin/printf 'FAIL: publish-release.sh resume mode does not verify the draft DMG image\n' >&2
    exit 1
fi
if ! /usr/bin/grep -Fq \
    'Cannot build the QuitHide DMG while another QuitHide disk image is mounted' \
    "$PROJECT_DIR/scripts/build-dmg.sh"; then
    /usr/bin/printf 'FAIL: build-dmg.sh does not guard against same-name mounted volumes\n' >&2
    exit 1
fi
if ! /usr/bin/grep -Fq \
    'Finder resolved the writable DMG to a different mounted volume' \
    "$PROJECT_DIR/scripts/configure-dmg-layout.applescript"; then
    /usr/bin/printf 'FAIL: Finder layout script does not detect alias resolution to the wrong volume\n' >&2
    exit 1
fi

/usr/bin/printf 'PASS: DMG layout rejects missing Finder metadata and is verified after packaging\n'
