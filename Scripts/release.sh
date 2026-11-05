#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
PROFILE=${NOTARY_PROFILE:-}
if [[ -z ${APP_IDENTITY:-} || ${SIGNING_MODE:-} == adhoc ]]; then
  echo "Set APP_IDENTITY to a Developer ID Application identity; release artifacts must not be ad-hoc signed." >&2
  exit 2
fi
if [[ ${1:-} == --notarize ]]; then
  PROFILE=${2:?Usage: Scripts/release.sh --notarize KEYCHAIN_PROFILE}
elif [[ $# -gt 0 ]]; then
  echo "Usage: Scripts/release.sh [--notarize KEYCHAIN_PROFILE]" >&2; exit 2
fi
ARCHES="arm64 x86_64" Scripts/package_app.sh release
mkdir -p dist
NAME="SplashFinish-${MARKETING_VERSION}-universal.zip"
APP="$ROOT/build/Splash Finish.app"
ZIP="$ROOT/dist/$NAME"
codesign --verify --deep --strict --verbose=2 "$APP"
# ditto preserves bundle metadata and signs no new content after sealing.
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "$PROFILE" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm "$ZIP"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "NOTE: Built a signed artifact without notarization. Set NOTARY_PROFILE for distribution."
fi
(cd dist && shasum -a 256 "$NAME" > SHA256SUMS)
echo "Release: $ZIP"
