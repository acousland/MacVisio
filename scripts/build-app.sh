#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
RELEASE_CHANNEL="${MACVISIO_RELEASE_CHANNEL:-development}"
SIGNING_IDENTITY="${MACVISIO_SIGNING_IDENTITY:--}"
if [[ "$RELEASE_CHANNEL" != development && "$RELEASE_CHANNEL" != stable ]]; then
  echo 'MACVISIO_RELEASE_CHANNEL must be development or stable' >&2; exit 1
fi
if [[ "$RELEASE_CHANNEL" == stable && "$SIGNING_IDENTITY" != 'Developer ID Application:'* ]]; then
  echo 'Stable candidates require an explicit Developer ID Application signing identity' >&2; exit 1
fi
swift build -c release
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="${MACVISIO_APP_DIR:-$PROJECT_DIR/build/MacVisio.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/MacVisio" "$APP_DIR/Contents/MacOS/MacVisio"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"
python3 scripts/release_policy.py configure-bundle "$APP_DIR" --channel "$RELEASE_CHANNEL"
python3 scripts/bundle-legacy.py "$APP_DIR"
python3 scripts/bundle-sparkle.py "$APP_DIR"
swift scripts/MakeIcon.swift "$PROJECT_DIR/build"
iconutil -c icns "$PROJECT_DIR/build/MacVisio.iconset" -o "$APP_DIR/Contents/Resources/MacVisio.icns"
python3 scripts/sign-app.py "$APP_DIR" "$SIGNING_IDENTITY"
printf 'Built %s\n' "$APP_DIR"
