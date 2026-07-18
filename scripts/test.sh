#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

cd "$PROJECT_DIR"

if /usr/bin/xcrun swift -e 'import Foundation; import Testing' >/dev/null 2>&1; then
    /usr/bin/xcrun swift test
elif /usr/bin/xcrun swift -F "$CLT_FRAMEWORKS" -e 'import Foundation; import Testing' >/dev/null 2>&1; then
    /usr/bin/xcrun swift test \
        -Xswiftc -F \
        -Xswiftc "$CLT_FRAMEWORKS" \
        -Xlinker "-F$CLT_FRAMEWORKS"
else
    CHECK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/QuitHide-tests.XXXXXX")"
    cleanup() {
        /bin/rm -rf "$CHECK_DIR"
    }
    trap cleanup EXIT

    /usr/bin/printf 'Swift Testing is incomplete; running portable regression checks.\n'
    /usr/bin/xcrun swiftc \
        Sources/QuitHide/AutomationTiming.swift \
        Sources/QuitHide/UpdateChecker.swift \
        Tests/PortableChecks/main.swift \
        -o "$CHECK_DIR/QuitHideRegressionChecks"
    "$CHECK_DIR/QuitHideRegressionChecks"
fi
