#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/MacVisio.app/Contents/Info.plist)
RELEASE_DIR="build/releases/$RELEASE_VERSION"
SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
mkdir -p "$RELEASE_DIR"
codesign --verify --deep --strict build/MacVisio.app
ditto -c -k --sequesterRsrc --keepParent build/MacVisio.app "$RELEASE_DIR/MacVisio-$RELEASE_VERSION.zip"
SIGN_ARGS=(--account MacVisio)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then SIGN_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
"$SPARKLE_TOOLS/generate_appcast" "${SIGN_ARGS[@]}" --maximum-deltas 0 --download-url-prefix "https://github.com/acousland/MacVisio/releases/download/v$RELEASE_VERSION/" --link https://github.com/acousland/MacVisio "$RELEASE_DIR"
"$SPARKLE_TOOLS/sign_update" "${SIGN_ARGS[@]}" --verify "$RELEASE_DIR/appcast.xml"
(cd "$RELEASE_DIR" && shasum -a 256 "MacVisio-$RELEASE_VERSION.zip" > SHA256SUMS.txt)
python3 scripts/verify-release.py "$RELEASE_DIR"
printf 'Release artifacts: %s\n' "$RELEASE_DIR"
