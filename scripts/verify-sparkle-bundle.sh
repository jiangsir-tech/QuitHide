#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    /usr/bin/printf 'Usage: %s /path/to/QuitHide.app\n' "${0:t}" >&2
    exit 64
fi

APP_DIR="$1"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/QuitHide"
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"

fail() {
    /usr/bin/printf 'Sparkle bundle verification failed: %s\n' "$1" >&2
    exit 1
}

signature_field() {
    local signed_path="$1"
    local field_name="$2"
    local signature_details
    local -a signature_lines matching_lines

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$signed_path" 2>&1)"
    signature_lines=("${(@f)signature_details}")
    matching_lines=("${(@M)signature_lines:#${field_name}=*}")
    (( ${#matching_lines[@]} == 1 )) || return 1
    /usr/bin/printf '%s\n' "${matching_lines[1]#${field_name}=}"
}

is_ad_hoc() {
    local signed_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$signed_path" 2>&1)"
    [[ "$signature_details" == *$'\nSignature=adhoc\n'* ]]
}

[[ -x "$APP_EXECUTABLE" ]] || fail "missing app executable: $APP_EXECUTABLE"
[[ -d "$SPARKLE_FRAMEWORK" ]] || fail "missing framework: $SPARKLE_FRAMEWORK"

# A flattened framework is not safe to ship. Sparkle's signature and helper
# discovery both rely on the versioned framework layout and these symlinks.
EXPECTED_SYMLINKS=(
    "$SPARKLE_FRAMEWORK/Versions/Current"
    "$SPARKLE_FRAMEWORK/Sparkle"
    "$SPARKLE_FRAMEWORK/Autoupdate"
    "$SPARKLE_FRAMEWORK/Updater.app"
    "$SPARKLE_FRAMEWORK/XPCServices"
    "$SPARKLE_FRAMEWORK/Resources"
    "$SPARKLE_FRAMEWORK/Headers"
    "$SPARKLE_FRAMEWORK/Modules"
)
for symlink_path in "${EXPECTED_SYMLINKS[@]}"; do
    [[ -L "$symlink_path" ]] || fail "expected preserved symlink: $symlink_path"
done
[[ "$(/usr/bin/readlink "$SPARKLE_FRAMEWORK/Versions/Current")" == "B" ]] \
    || fail "Sparkle.framework/Versions/Current does not point to B"

SPARKLE_EXECUTABLES=(
    "$SPARKLE_VERSION_DIR/Sparkle"
    "$SPARKLE_VERSION_DIR/Autoupdate"
    "$SPARKLE_VERSION_DIR/Updater.app/Contents/MacOS/Updater"
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
)
for executable_path in "${SPARKLE_EXECUTABLES[@]}"; do
    [[ -x "$executable_path" ]] || fail "missing executable helper: $executable_path"
    /usr/bin/lipo "$executable_path" -verify_arch arm64 \
        || fail "missing arm64 slice: $executable_path"
    /usr/bin/lipo "$executable_path" -verify_arch x86_64 \
        || fail "missing x86_64 slice: $executable_path"
done

LINKED_LIBRARIES="$(/usr/bin/otool -L "$APP_EXECUTABLE")"
[[ "$LINKED_LIBRARIES" == *'@rpath/Sparkle.framework/Versions/B/Sparkle'* ]] \
    || fail "QuitHide does not link against the bundled Sparkle framework"
LOAD_COMMANDS="$(/usr/bin/otool -l "$APP_EXECUTABLE")"
[[ "$LOAD_COMMANDS" == *'@loader_path/../Frameworks'* ]] \
    || fail "QuitHide is missing @loader_path/../Frameworks in LC_RPATH"

SPARKLE_SIGNED_COMPONENTS=(
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
    "$SPARKLE_VERSION_DIR/Autoupdate"
    "$SPARKLE_VERSION_DIR/Updater.app"
    "$SPARKLE_FRAMEWORK"
)
SIGNED_COMPONENTS=(
    "${SPARKLE_SIGNED_COMPONENTS[@]}"
    "$APP_DIR"
)
for signed_path in "${SIGNED_COMPONENTS[@]}"; do
    /usr/bin/codesign --verify --strict "$signed_path" \
        || fail "invalid code signature: $signed_path"
done
/usr/bin/codesign --verify --deep --strict "$APP_DIR" \
    || fail "invalid nested code signature: $APP_DIR"

if is_ad_hoc "$APP_DIR"; then
    for signed_path in "${SPARKLE_SIGNED_COMPONENTS[@]}"; do
        is_ad_hoc "$signed_path" || fail "expected ad-hoc signature for $signed_path"
    done
    SIGNATURE_SUMMARY="ad-hoc"
else
    APP_TEAM_ID="$(signature_field "$APP_DIR" TeamIdentifier)"
    [[ -n "$APP_TEAM_ID" && "$APP_TEAM_ID" != "not set" ]] \
        || fail "Developer ID build has no app TeamIdentifier"
    for signed_path in "${SPARKLE_SIGNED_COMPONENTS[@]}"; do
        if is_ad_hoc "$signed_path"; then
            fail "expected a certificate signature for $signed_path"
        fi
        component_team_id="$(signature_field "$signed_path" TeamIdentifier)"
        [[ "$component_team_id" == "$APP_TEAM_ID" ]] \
            || fail "TeamIdentifier mismatch for $signed_path (app=$APP_TEAM_ID, component=$component_team_id)"
    done
    SIGNATURE_SUMMARY="TeamIdentifier=$APP_TEAM_ID"
fi

/usr/bin/printf 'Verified Sparkle bundle: %s (%s)\n' \
    "$SPARKLE_FRAMEWORK" \
    "$SIGNATURE_SUMMARY"
