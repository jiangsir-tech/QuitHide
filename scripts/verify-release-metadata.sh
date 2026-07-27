#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${1:-${0:A:h:h}}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
UPDATE_JSON="$PROJECT_DIR/update.json"
RELEASE_HISTORY_JSON="$PROJECT_DIR/release-history.json"
RELEASE_NOTES_GENERATOR="$PROJECT_DIR/website/scripts/create-sparkle-release-notes.mjs"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
APP_MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"

IFS=$'\t' read -r MANIFEST_VERSION MANIFEST_BUILD MANIFEST_MINIMUM_SYSTEM MANIFEST_DOWNLOAD_URL < <(
    /usr/bin/python3 -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    manifest = json.load(stream)

required = {
    "version": str,
    "build": int,
    "minimumSystemVersion": str,
    "releaseNotes": str,
    "releaseNotesEn": str,
    "downloadURL": str,
}
for key, expected_type in required.items():
    if key not in manifest or type(manifest[key]) is not expected_type:
        raise SystemExit(f"Invalid update.json field: {key}")
for notes_key in ("releaseNotes", "releaseNotesEn"):
    if not manifest[notes_key].strip():
        raise SystemExit(f"update.json {notes_key} must not be empty")

print(
    manifest["version"],
    manifest["build"],
    manifest["minimumSystemVersion"],
    manifest["downloadURL"],
    sep="\t",
)
' "$UPDATE_JSON"
)

EXPECTED_VERSION="${QUITHIDE_EXPECTED_VERSION:-$APP_VERSION}"
EXPECTED_BUILD="${QUITHIDE_EXPECTED_BUILD:-$APP_BUILD}"
EXPECTED_DOWNLOAD_URL="https://github.com/jiangsir-tech/QuitHide/releases/tag/v${APP_VERSION}"

if [[ ! "$APP_VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
    /usr/bin/printf 'Invalid stable app version: %s\n' "$APP_VERSION" >&2
    exit 1
fi
if [[ ! "$APP_BUILD" =~ '^(0|[1-9][0-9]*)$' ]]; then
    /usr/bin/printf 'Invalid app build: %s\n' "$APP_BUILD" >&2
    exit 1
fi
if [[ "$APP_VERSION" != "$EXPECTED_VERSION" || "$MANIFEST_VERSION" != "$EXPECTED_VERSION" ]]; then
    /usr/bin/printf 'Version mismatch: plist=%s manifest=%s expected=%s\n' \
        "$APP_VERSION" "$MANIFEST_VERSION" "$EXPECTED_VERSION" >&2
    exit 1
fi
if [[ "$APP_BUILD" != "$EXPECTED_BUILD" || "$MANIFEST_BUILD" != "$EXPECTED_BUILD" ]]; then
    /usr/bin/printf 'Build mismatch: plist=%s manifest=%s expected=%s\n' \
        "$APP_BUILD" "$MANIFEST_BUILD" "$EXPECTED_BUILD" >&2
    exit 1
fi
if [[ "$APP_MINIMUM_SYSTEM" != "$MANIFEST_MINIMUM_SYSTEM" ]]; then
    /usr/bin/printf 'Minimum-system mismatch: plist=%s manifest=%s\n' \
        "$APP_MINIMUM_SYSTEM" "$MANIFEST_MINIMUM_SYSTEM" >&2
    exit 1
fi
if [[ "$MANIFEST_DOWNLOAD_URL" != "$EXPECTED_DOWNLOAD_URL" ]]; then
    /usr/bin/printf 'Unexpected download URL: %s\nExpected: %s\n' \
        "$MANIFEST_DOWNLOAD_URL" "$EXPECTED_DOWNLOAD_URL" >&2
    exit 1
fi

/usr/bin/env node "$RELEASE_NOTES_GENERATOR" \
    --history "$RELEASE_HISTORY_JSON" \
    --manifest "$UPDATE_JSON" \
    --output /dev/null

/usr/bin/printf 'Release metadata verified: %s (%s), macOS %s+\n' \
    "$APP_VERSION" "$APP_BUILD" "$APP_MINIMUM_SYSTEM"
