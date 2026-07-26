#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$DIST_DIR/QuitHide-v${VERSION}-universal.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_PATH="$DIST_DIR/QuitHide-v${VERSION}-appcast.xml"
SIGNING_IDENTITY="${QUITHIDE_SIGNING_IDENTITY:-Developer ID Application: Yongjiang Li (93GC94J9B6)}"
NOTARY_PROFILE="${QUITHIDE_NOTARY_PROFILE:-QuitHide-notary}"
TAG_NAME="v${VERSION}"
REUSE_LOCAL_ARTIFACTS="${QUITHIDE_REUSE_LOCAL_ARTIFACTS:-0}"

if [[ -n "$(/usr/bin/git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)" ]]; then
    /usr/bin/printf 'Release requires a clean Git worktree, including untracked files.\n' >&2
    exit 1
fi

CURRENT_BRANCH="$(/usr/bin/git -C "$PROJECT_DIR" branch --show-current)"
if [[ -z "$CURRENT_BRANCH" ]]; then
    /usr/bin/printf 'Release requires a named branch, not a detached HEAD.\n' >&2
    exit 1
fi
if [[ "$CURRENT_BRANCH" == "main" ]]; then
    /usr/bin/printf 'Release must run from a pushed release branch; the verified workflow updates main last.\n' >&2
    exit 1
fi
if ! UPSTREAM_REF="$(/usr/bin/git -C "$PROJECT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    /usr/bin/printf 'Release branch has no upstream. Push it before building release assets.\n' >&2
    exit 1
fi
UPSTREAM_REMOTE="${UPSTREAM_REF%%/*}"
/usr/bin/git -C "$PROJECT_DIR" fetch --quiet "$UPSTREAM_REMOTE" "$CURRENT_BRANCH"
if [[ "$(/usr/bin/git -C "$PROJECT_DIR" rev-parse HEAD)" != "$(/usr/bin/git -C "$PROJECT_DIR" rev-parse "$UPSTREAM_REF")" ]]; then
    /usr/bin/printf 'Release HEAD must exactly match its pushed upstream branch.\n' >&2
    exit 1
fi

"$PROJECT_DIR/scripts/verify-release-metadata.sh" "$PROJECT_DIR"
"$PROJECT_DIR/scripts/test.sh"

REMOTE_URL="$(/usr/bin/git -C "$PROJECT_DIR" remote get-url origin)"
REMOTE_TAGS="$(/usr/bin/git ls-remote --tags "$REMOTE_URL" "refs/tags/$TAG_NAME" "refs/tags/$TAG_NAME^{}")"
if [[ -n "$REMOTE_TAGS" ]]; then
    /usr/bin/printf 'Remote tag already exists: %s\n' "$TAG_NAME" >&2
    exit 1
fi

if ! /usr/bin/command -v gh >/dev/null 2>&1; then
    /usr/bin/printf 'GitHub CLI is required to check existing draft releases.\n' >&2
    exit 1
fi
if [[ "$(gh release list --limit 100 --json tagName --jq \
    "any(.[]; .tagName == \"$TAG_NAME\")")" == "true" ]]; then
    /usr/bin/printf 'A GitHub release already exists for tag: %s\n' "$TAG_NAME" >&2
    exit 1
fi

if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" || -e "$APPCAST_PATH" ]]; then
    if [[ "$REUSE_LOCAL_ARTIFACTS" != "1" ]]; then
        /usr/bin/printf 'Refusing to overwrite an existing release artifact: %s\n' "$DMG_PATH" >&2
        /usr/bin/printf 'Set QUITHIDE_REUSE_LOCAL_ARTIFACTS=1 only to verify and resume this exact release.\n' >&2
        exit 1
    fi
    for artifact in "$DMG_PATH" "$CHECKSUM_PATH"; do
        if [[ ! -f "$artifact" ]]; then
            /usr/bin/printf 'Cannot resume because an expected artifact is missing: %s\n' "$artifact" >&2
            exit 1
        fi
    done
    /usr/bin/xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG_PATH"
    (
        cd "$DIST_DIR"
        /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
    )
    if [[ ! -f "$APPCAST_PATH" ]]; then
        "$PROJECT_DIR/scripts/create-sparkle-appcast.sh"
    else
        PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
        /usr/bin/env node "$PROJECT_DIR/website/scripts/verify-sparkle-release.mjs" \
            --manifest "$PROJECT_DIR/update.json" \
            --dmg "$DMG_PATH" \
            --checksum "$CHECKSUM_PATH" \
            --appcast "$APPCAST_PATH" \
            --download-base-url "${QUITHIDE_DOWNLOAD_BASE_URL:-https://quithide-downloads-1313533016.cos.ap-hongkong.myqcloud.com}" \
            --public-key "$PUBLIC_KEY" >/dev/null
    fi
    /usr/bin/printf 'Reused verified notarized release artifacts for %s.\n' "$TAG_NAME"
    exit 0
fi

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

"$PROJECT_DIR/scripts/create-sparkle-appcast.sh"

/usr/bin/printf 'Notarized release: %s\n' "$DMG_PATH"
/usr/bin/printf 'SHA-256: '
/usr/bin/awk '{print $1}' "$CHECKSUM_PATH"
/usr/bin/printf 'Sparkle appcast: %s\n' "$APPCAST_PATH"
