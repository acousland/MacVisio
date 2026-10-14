#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/MacVisio.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/MacVisio" "$APP_DIR/Contents/MacOS/MacVisio"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"
python3 scripts/bundle-legacy.py "$APP_DIR"
python3 scripts/bundle-sparkle.py "$APP_DIR"
swift scripts/MakeIcon.swift "$PROJECT_DIR/build"
iconutil -c icns "$PROJECT_DIR/build/MacVisio.iconset" -o "$APP_DIR/Contents/Resources/MacVisio.icns"
SIGNING_IDENTITY="${MACVISIO_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
