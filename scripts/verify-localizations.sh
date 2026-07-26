#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
SOURCE_LOCALIZATION_DIR="$PROJECT_DIR/Sources/QuitHide/Resources"
EXPECTED_DEVELOPMENT_REGION="zh-Hans"
EXPECTED_LOCALES=(zh-Hans en)
APP_PATH=""
CHECK_SIGNATURE=0
CHECK_ARCHITECTURES=0

usage() {
    /usr/bin/printf '%s\n' \
        'Usage: verify-localizations.sh [--app PATH] [--check-signature] [--check-architectures]'
}

fail() {
    /usr/bin/printf 'Localization verification failed: %s\n' "$1" >&2
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || fail '--app requires a path'
            APP_PATH="$2"
            shift 2
            ;;
        --check-signature)
            CHECK_SIGNATURE=1
            shift
            ;;
        --check-architectures)
            CHECK_ARCHITECTURES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

if (( (CHECK_SIGNATURE || CHECK_ARCHITECTURES) && ${#APP_PATH} == 0 )); then
    fail '--check-signature and --check-architectures require --app'
fi

expected_locale_list() {
    /usr/bin/printf '%s\n' "${EXPECTED_LOCALES[@]}" | /usr/bin/sort
}

locale_list() {
    local root="$1"
    local directory
    local -a locales=()

    for directory in "$root"/*.lproj(N); do
        locales+=("$(/usr/bin/basename "$directory" .lproj)")
    done
    if (( ${#locales[@]} > 0 )); then
        /usr/bin/printf '%s\n' "${locales[@]}" | /usr/bin/sort
    fi
}

keys_for_strings() {
    local strings_file="$1"

    /usr/bin/plutil -convert json -o - "$strings_file" |
        /usr/bin/python3 -c '
import json
import sys

table = json.load(sys.stdin)
if not isinstance(table, dict) or not table:
    raise SystemExit("Localizable.strings must contain a non-empty dictionary")
invalid = [
    key
    for key, value in table.items()
    if not isinstance(key, str)
    or not key.strip()
    or not isinstance(value, str)
    or not value.strip()
]
if invalid:
    raise SystemExit("Localizable.strings keys and values must be non-empty strings")
print("\n".join(sorted(table)))
'
}

localizations_for_info() {
    local info_plist="$1"

    /usr/bin/plutil -extract CFBundleLocalizations json -o - "$info_plist" |
        /usr/bin/python3 -c '
import json
import sys

locales = json.load(sys.stdin)
if not isinstance(locales, list) or any(not isinstance(locale, str) for locale in locales):
    raise SystemExit("CFBundleLocalizations must be an array of strings")
print("\n".join(sorted(locales)))
'
}

validate_info_plist() {
    local info_plist="$1"
    local label="$2"
    local development_region
    local declared_locales

    [[ -f "$info_plist" ]] || fail "$label Info.plist is missing: $info_plist"
    /usr/bin/plutil -lint "$info_plist" >/dev/null
    development_region="$(
        /usr/bin/plutil -extract CFBundleDevelopmentRegion raw -o - "$info_plist"
    )"
    [[ "$development_region" == "$EXPECTED_DEVELOPMENT_REGION" ]] ||
        fail "$label development region is $development_region, expected $EXPECTED_DEVELOPMENT_REGION"

    declared_locales="$(localizations_for_info "$info_plist")"
    [[ "$declared_locales" == "$(expected_locale_list)" ]] ||
        fail "$label CFBundleLocalizations must contain exactly: ${EXPECTED_LOCALES[*]}"
}

validate_localization_root() {
    local root="$1"
    local label="$2"
    local actual_locales
    local baseline_keys=""
    local locale
    local strings_file
    local keys

    [[ -d "$root" ]] || fail "$label localization directory is missing: $root"
    actual_locales="$(locale_list "$root")"
    [[ "$actual_locales" == "$(expected_locale_list)" ]] ||
        fail "$label must contain exactly these .lproj directories: ${EXPECTED_LOCALES[*]}"

    for locale in "${EXPECTED_LOCALES[@]}"; do
        strings_file="$root/$locale.lproj/Localizable.strings"
        [[ -f "$strings_file" ]] || fail "$label is missing: $strings_file"
        /usr/bin/plutil -lint "$strings_file" >/dev/null
        keys="$(keys_for_strings "$strings_file")"
        if [[ -z "$baseline_keys" ]]; then
            baseline_keys="$keys"
        elif [[ "$keys" != "$baseline_keys" ]]; then
            fail "$label localization keys do not match for locale: $locale"
        fi
    done
}

validate_info_plist "$SOURCE_INFO_PLIST" 'source'
validate_localization_root "$SOURCE_LOCALIZATION_DIR" 'source'

if [[ -n "$APP_PATH" ]]; then
    APP_PATH="${APP_PATH:A}"
    APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
    APP_RESOURCE_DIR="$APP_PATH/Contents/Resources"

    [[ -d "$APP_PATH" ]] || fail "App bundle is missing: $APP_PATH"
    validate_info_plist "$APP_INFO_PLIST" 'App'
    validate_localization_root "$APP_RESOURCE_DIR" 'App'

    for locale in "${EXPECTED_LOCALES[@]}"; do
        /usr/bin/cmp -s \
            "$SOURCE_LOCALIZATION_DIR/$locale.lproj/Localizable.strings" \
            "$APP_RESOURCE_DIR/$locale.lproj/Localizable.strings" ||
            fail "App $locale Localizable.strings differs from the source file"
    done

    if (( CHECK_ARCHITECTURES )); then
        APP_EXECUTABLE="$(
            /usr/bin/plutil -extract CFBundleExecutable raw -o - "$APP_INFO_PLIST"
        )"
        APP_BINARY="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
        [[ -f "$APP_BINARY" ]] || fail "App executable is missing: $APP_BINARY"
        /usr/bin/lipo "$APP_BINARY" -verify_arch arm64
        /usr/bin/lipo "$APP_BINARY" -verify_arch x86_64
    fi

    if (( CHECK_SIGNATURE )); then
        /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    fi
fi

if [[ -n "$APP_PATH" ]]; then
    /usr/bin/printf 'Localizations verified: zh-Hans and en in %s\n' "$APP_PATH"
else
    /usr/bin/printf 'Source localizations verified: zh-Hans and en\n'
fi
