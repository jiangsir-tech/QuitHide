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

/usr/bin/printf 'Running portable regression checks.\n'
/usr/bin/xcrun swiftc \
    Sources/QuitHide/AutomationPolicy.swift \
    Sources/QuitHide/AppRuleRegistry.swift \
    Sources/QuitHide/AutomationTiming.swift \
    Sources/QuitHide/MenuHeightPolicy.swift \
    Sources/QuitHide/QuitRequestPolicy.swift \
    Sources/QuitHide/UpdateReminderPolicy.swift \
    Sources/QuitHide/UpdateChecker.swift \
    Tests/PortableChecks/main.swift \
    -o "$CHECK_DIR/QuitHideRegressionChecks"
"$CHECK_DIR/QuitHideRegressionChecks"

# Documents may gain File Provider xattrs that invalidate the ad-hoc signature
# of the XCTest bundle. Building in a fresh system temporary directory avoids
# that environmental failure and ensures the Swift Testing suites always run.
/usr/bin/printf 'Running Swift Testing suites.\n'
/usr/bin/xcrun swift test --scratch-path "$SWIFT_TEST_DIR"
