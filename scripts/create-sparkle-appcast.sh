#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
MANIFEST_PATH="$PROJECT_DIR/update.json"
RELEASE_HISTORY_PATH="$PROJECT_DIR/release-history.json"
RELEASE_NOTES_GENERATOR="$PROJECT_DIR/website/scripts/create-sparkle-release-notes.mjs"
DIST_DIR="$PROJECT_DIR/dist"
/bin/mkdir -p "$DIST_DIR"
DOWNLOAD_BASE_URL="${QUITHIDE_DOWNLOAD_BASE_URL:-https://quithide-downloads-1313533016.cos.ap-hongkong.myqcloud.com}"
SPARKLE_ACCOUNT="${QUITHIDE_SPARKLE_ACCOUNT:-ed25519}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
TAG_NAME="v${VERSION}"
DMG_NAME="QuitHide-v${VERSION}-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_NAME="QuitHide-v${VERSION}-appcast.xml"
APPCAST_PATH="$DIST_DIR/$APPCAST_NAME"
STAGING_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/.QuitHide-appcast.XXXXXX")"

cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ "$DOWNLOAD_BASE_URL" != https://* || "$DOWNLOAD_BASE_URL" == *\?* || "$DOWNLOAD_BASE_URL" == *\#* ]]; then
    /usr/bin/printf 'QUITHIDE_DOWNLOAD_BASE_URL must be a plain HTTPS base URL.\n' >&2
    exit 1
fi
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"

for artifact in "$DMG_PATH" "$CHECKSUM_PATH"; do
    if [[ ! -f "$artifact" ]]; then
        /usr/bin/printf 'Missing release artifact: %s\n' "$artifact" >&2
        exit 1
    fi
done
if [[ -e "$APPCAST_PATH" ]]; then
    /usr/bin/printf 'Refusing to overwrite an existing appcast artifact: %s\n' "$APPCAST_PATH" >&2
    exit 1
fi

GENERATE_APPCAST="${QUITHIDE_GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" ]]; then
    for candidate in \
        "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/generate_appcast"; do
        if [[ -x "$candidate" ]]; then
            GENERATE_APPCAST="$candidate"
            break
        fi
    done
fi
if [[ -z "$GENERATE_APPCAST" ]] && /usr/bin/command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="$(/usr/bin/command -v generate_appcast)"
fi
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    /usr/bin/printf 'Sparkle generate_appcast was not found. Resolve the pinned Swift package or set QUITHIDE_GENERATE_APPCAST.\n' >&2
    exit 1
fi
GENERATE_KEYS="${GENERATE_APPCAST:h}/generate_keys"
if [[ ! -x "$GENERATE_KEYS" ]]; then
    /usr/bin/printf 'Sparkle generate_keys was not found next to generate_appcast.\n' >&2
    exit 1
fi

BUNDLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
KEYCHAIN_PUBLIC_KEY="$($GENERATE_KEYS --account "$SPARKLE_ACCOUNT" -p)"
if [[ -z "$BUNDLE_PUBLIC_KEY" || "$BUNDLE_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]]; then
    /usr/bin/printf 'The app public key does not match the Sparkle key in account %s.\n' "$SPARKLE_ACCOUNT" >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO_PLIST")" != "true" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO_PLIST")" != "true" ]]; then
    /usr/bin/printf 'Signed-feed and pre-extraction verification must both be enabled.\n' >&2
    exit 1
fi

/bin/cp "$DMG_PATH" "$STAGING_DIR/$DMG_NAME"
if [[ -f "$PROJECT_DIR/website/src/appcast.xml" ]]; then
    # generate_appcast reuses only the exact output path passed with -o.
    # Seed that versioned path so older feed items survive the next release.
    /bin/cp "$PROJECT_DIR/website/src/appcast.xml" "$STAGING_DIR/$APPCAST_NAME"
fi

/usr/bin/env node "$RELEASE_NOTES_GENERATOR" \
    --history "$RELEASE_HISTORY_PATH" \
    --manifest "$MANIFEST_PATH" \
    --output "$STAGING_DIR/${DMG_NAME:r}.html"

(
    cd "$STAGING_DIR"
    "$GENERATE_APPCAST" \
        --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "$DOWNLOAD_BASE_URL/releases/$TAG_NAME/" \
        --full-release-notes-url "https://quithide.com/changelog/" \
        --maximum-versions 5 \
        --maximum-deltas 0 \
        --embed-release-notes \
        -o "$APPCAST_NAME" \
        "$STAGING_DIR"
)

if [[ ! -f "$STAGING_DIR/$APPCAST_NAME" ]]; then
    /usr/bin/printf 'Sparkle did not generate %s.\n' "$APPCAST_NAME" >&2
    exit 1
fi
/usr/bin/env node "$PROJECT_DIR/website/scripts/verify-sparkle-release.mjs" \
    --manifest "$MANIFEST_PATH" \
    --dmg "$DMG_PATH" \
    --checksum "$CHECKSUM_PATH" \
    --appcast "$STAGING_DIR/$APPCAST_NAME" \
    --release-history "$RELEASE_HISTORY_PATH" \
    --download-base-url "$DOWNLOAD_BASE_URL" \
    --public-key "$BUNDLE_PUBLIC_KEY" >/dev/null

# Publish the generated feed only after every signature and metadata check has
# passed, so a failed run never leaves an unusable final artifact behind.
/bin/mv "$STAGING_DIR/$APPCAST_NAME" "$APPCAST_PATH"

/usr/bin/printf 'Signed Sparkle appcast: %s\n' "$APPCAST_PATH"
