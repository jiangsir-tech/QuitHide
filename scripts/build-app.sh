#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/QuitHide.app"

cd "$PROJECT_DIR"
/usr/bin/xcrun swift build -c release --arch arm64 --scratch-path "$PROJECT_DIR/.build/arm64"
/usr/bin/xcrun swift build -c release --arch x86_64 --scratch-path "$PROJECT_DIR/.build/x86_64"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/usr/bin/lipo -create \
    ".build/arm64/arm64-apple-macosx/release/QuitHide" \
    ".build/x86_64/x86_64-apple-macosx/release/QuitHide" \
    -output "$APP_DIR/Contents/MacOS/QuitHide"
/bin/cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/bin/cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/bin/chmod 755 "$APP_DIR/Contents/MacOS/QuitHide"
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/QuitHide"

/usr/bin/printf 'Built: %s\n' "$APP_DIR"
