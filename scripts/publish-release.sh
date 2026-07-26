#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
MANIFEST_PATH="$PROJECT_DIR/update.json"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
TAG_NAME="v${VERSION}"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/QuitHide-v${VERSION}-universal.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_PATH="$DIST_DIR/QuitHide-v${VERSION}-appcast.xml"
RELEASE_NOTES_PATH="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/QuitHide-release-notes.XXXXXX")"
RESUME_MODE="${QUITHIDE_RESUME:-0}"

cleanup() {
    /bin/rm -f "$RELEASE_NOTES_PATH"
}
trap cleanup EXIT

if ! /usr/bin/command -v gh >/dev/null 2>&1; then
    /usr/bin/printf 'GitHub CLI is required to publish QuitHide.\n' >&2
    exit 1
fi
gh auth status >/dev/null

RELEASE_COMMIT="$(/usr/bin/git -C "$PROJECT_DIR" rev-parse HEAD)"
if [[ "$RESUME_MODE" == "1" ]]; then
    RELEASE_JSON="$(gh api "repos/jiangsir-tech/QuitHide/releases/tags/$TAG_NAME")"
    /usr/bin/printf 'Resuming existing GitHub release workflow for %s.\n' "$TAG_NAME"
else
    "$PROJECT_DIR/scripts/release-notarized.sh"

    /usr/bin/python3 - "$MANIFEST_PATH" "$RELEASE_NOTES_PATH" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
body = (
    f"## 简体中文\n\n{manifest['releaseNotes'].strip()}\n\n"
    f"## English\n\n{manifest['releaseNotesEn'].strip()}\n\n"
    f"macOS {manifest['minimumSystemVersion']} 或更高版本 / or later.\n"
)
pathlib.Path(sys.argv[2]).write_text(body, encoding="utf-8")
PY

    gh release create "$TAG_NAME" \
        "$DMG_PATH" \
        "$CHECKSUM_PATH" \
        "$APPCAST_PATH" \
        --repo jiangsir-tech/QuitHide \
        --draft \
        --target "$RELEASE_COMMIT" \
        --title "QuitHide $TAG_NAME" \
        --notes-file "$RELEASE_NOTES_PATH"

    RELEASE_JSON="$(gh api "repos/jiangsir-tech/QuitHide/releases/tags/$TAG_NAME")"
fi
if [[ "$(jq -r '.prerelease' <<<"$RELEASE_JSON")" != "false" ]]; then
    /usr/bin/printf 'The GitHub release is unexpectedly marked as a prerelease.\n' >&2
    exit 1
fi
if [[ "$(jq -r '.target_commitish' <<<"$RELEASE_JSON")" != "$RELEASE_COMMIT" ]]; then
    /usr/bin/printf 'GitHub release target does not match the local release commit.\n' >&2
    exit 1
fi

/usr/bin/printf 'Verified GitHub release target: %s\n' "$TAG_NAME"
if [[ "${QUITHIDE_DRAFT_ONLY:-0}" == "1" ]]; then
    if [[ "$(jq -r '.draft' <<<"$RELEASE_JSON")" != "true" ]]; then
        /usr/bin/printf 'Draft-only mode requested, but the release is already published.\n' >&2
        exit 1
    fi
    /usr/bin/printf 'Draft-only mode enabled; publication workflow was not dispatched.\n'
    exit 0
fi

DISPATCHED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
gh workflow run publish-product-site.yml \
    --repo jiangsir-tech/QuitHide \
    --ref main \
    --raw-field "tag=$TAG_NAME"

RUN_ID=""
for _ in {1..30}; do
    RUN_ID="$(gh run list \
        --repo jiangsir-tech/QuitHide \
        --workflow publish-product-site.yml \
        --event workflow_dispatch \
        --limit 20 \
        --json databaseId,displayTitle,createdAt \
        --jq ".[] | select(.displayTitle == \"Publish QuitHide $TAG_NAME\" and .createdAt >= \"$DISPATCHED_AT\") | .databaseId" \
        | /usr/bin/head -n 1)"
    [[ -n "$RUN_ID" ]] && break
    /bin/sleep 2
done
if [[ -z "$RUN_ID" ]]; then
    /usr/bin/printf 'The publication workflow was dispatched, but its run could not be located.\n' >&2
    exit 1
fi

gh run watch "$RUN_ID" --repo jiangsir-tech/QuitHide --exit-status
/usr/bin/printf 'Published and verified QuitHide %s.\n' "$TAG_NAME"
