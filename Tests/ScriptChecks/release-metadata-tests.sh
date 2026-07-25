#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
VERIFY_SCRIPT="$PROJECT_DIR/scripts/verify-release-metadata.sh"

"$VERIFY_SCRIPT" "$PROJECT_DIR" >/dev/null

if QUITHIDE_EXPECTED_VERSION="999.0.0" "$VERIFY_SCRIPT" "$PROJECT_DIR" >/dev/null 2>&1; then
    /usr/bin/printf 'FAIL: release metadata accepted an unexpected version\n' >&2
    exit 1
fi
if QUITHIDE_EXPECTED_BUILD="999" "$VERIFY_SCRIPT" "$PROJECT_DIR" >/dev/null 2>&1; then
    /usr/bin/printf 'FAIL: release metadata accepted an unexpected build\n' >&2
    exit 1
fi

/usr/bin/printf 'PASS: release metadata consistency and mismatch guards\n'
