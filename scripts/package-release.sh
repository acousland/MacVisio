#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No environment variable can weaken stable verification. Default CI is development.
CHANNEL=development
MANIFEST=
CANDIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --candidate-only) CANDIDATE_ONLY=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$CHANNEL" == stable || "$CHANNEL" == development ]] || { echo 'Invalid channel' >&2; exit 1; }
if [[ "$CHANNEL" == stable && "$CANDIDATE_ONLY" == false && -z "$MANIFEST" ]]; then
  echo 'Stable packaging requires --manifest, or --candidate-only to prepare unaccepted artifacts' >&2; exit 1
fi
APP_DIR="${MACVISIO_APP_DIR:-build/MacVisio.app}"
RELEASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
python3 - "$APP_DIR" "$CHANNEL" "$RELEASE_VERSION" <<'PY'
import plistlib,re,sys
from pathlib import Path
sys.path.insert(0,'scripts')
from release_policy import check_bundle_channel,require
check_bundle_channel(plistlib.loads((Path(sys.argv[1])/'Contents/Info.plist').read_bytes()),sys.argv[2])
require(re.fullmatch(r'\d+\.\d+\.\d+',sys.argv[3]), 'Release version must be numeric major.minor.patch')
PY
REVISION=$(git rev-parse --short=12 HEAD)
if [[ "$CHANNEL" == stable ]]; then
  RELEASE_DIR="build/releases/stable-candidates/$RELEASE_VERSION"
  RELEASE_TAG="v$RELEASE_VERSION"
else
  RELEASE_DIR="build/releases/development/$RELEASE_VERSION-$REVISION"
  RELEASE_TAG="development-v$RELEASE_VERSION-$REVISION"
fi
# Never reuse stale appcasts or archives from an earlier candidate.
[[ ! -e "$RELEASE_DIR" ]] || { echo "Refusing to replace existing candidate: $RELEASE_DIR" >&2; exit 1; }
SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
mkdir -p "$RELEASE_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$RELEASE_DIR/MacVisio-$RELEASE_VERSION.zip"
SIGN_ARGS=(--account MacVisio)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then SIGN_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
"$SPARKLE_TOOLS/generate_appcast" "${SIGN_ARGS[@]}" --maximum-deltas 0 --download-url-prefix "https://github.com/acousland/MacVisio/releases/download/$RELEASE_TAG/" --link https://github.com/acousland/MacVisio "$RELEASE_DIR"
VERIFY_ARGS=(--channel "$CHANNEL")
if [[ -n "$MANIFEST" ]]; then VERIFY_ARGS+=(--manifest "$MANIFEST"); fi
if [[ "$CANDIDATE_ONLY" == true ]]; then VERIFY_ARGS+=(--candidate-only); fi
python3 scripts/verify-release.py "$RELEASE_DIR" "${VERIFY_ARGS[@]}"
(cd "$RELEASE_DIR" && shasum -a 256 "MacVisio-$RELEASE_VERSION.zip" > SHA256SUMS.txt)
printf 'Release artifacts (%s): %s\n' "$CHANNEL" "$RELEASE_DIR"
