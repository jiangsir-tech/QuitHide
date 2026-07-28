#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CHECK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-portable-tests.XXXXXX")"
SWIFT_TEST_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-swift-tests.XXXXXX")"

cleanup() {
    /bin/rm -rf "$CHECK_DIR" "$SWIFT_TEST_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"

/usr/bin/printf 'Running release metadata script checks.\n'
"$PROJECT_DIR/Tests/ScriptChecks/release-metadata-tests.sh"

/usr/bin/printf 'Running DMG layout script checks.\n'
"$PROJECT_DIR/Tests/ScriptChecks/dmg-layout-tests.sh"

/usr/bin/printf 'Running product website checks.\n'
/usr/bin/env npm --prefix "$PROJECT_DIR/website" test

/usr/bin/printf 'Running portable regression checks.\n'
/usr/bin/xcrun swiftc \
    Sources/QuitHide/AutomationPolicy.swift \
    Sources/QuitHide/AppRuleRegistry.swift \
    Sources/QuitHide/AutomationTiming.swift \
    Sources/QuitHide/AutomaticWindowProtection.swift \
    Sources/QuitHide/ScreenVisibilityProtection.swift \
    Sources/QuitHide/StageManagerGroupProtection.swift \
    Sources/QuitHide/StageManagerSystemStateProvider.swift \
    Sources/QuitHide/MenuHeightPolicy.swift \
    Sources/QuitHide/QuitRequestPolicy.swift \
    Tests/PortableChecks/main.swift \
    -o "$CHECK_DIR/QuitHideRegressionChecks"
"$CHECK_DIR/QuitHideRegressionChecks"

# Documents may gain File Provider xattrs that invalidate the ad-hoc signature
# of the XCTest bundle. Building in a fresh system temporary directory avoids
# that environmental failure and ensures the Swift Testing suites always run.
/usr/bin/printf 'Running Swift Testing suites.\n'
/usr/bin/xcrun swift build --build-tests --scratch-path "$SWIFT_TEST_DIR"
SWIFT_TEST_BIN_DIR="$(/usr/bin/xcrun swift build \
    --scratch-path "$SWIFT_TEST_DIR" \
    --show-bin-path)"
SPARKLE_FRAMEWORK="$SWIFT_TEST_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    /usr/bin/printf 'Sparkle framework was not resolved at: %s\n' "$SPARKLE_FRAMEWORK" >&2
    exit 1
fi
/bin/mkdir -p "$SWIFT_TEST_BIN_DIR/PackageFrameworks"
/usr/bin/ditto --norsrc \
    "$SPARKLE_FRAMEWORK" \
    "$SWIFT_TEST_BIN_DIR/PackageFrameworks/Sparkle.framework"
/usr/bin/xcrun swift test --skip-build --scratch-path "$SWIFT_TEST_DIR"
