#!/usr/bin/env bash
# Generate a signed appcast for one already-notarized release archive.
# The signing key remains in the login Keychain. Never commit/export it here.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
SPARKLE_BIN=${SPARKLE_BIN:-"$ROOT/.build/sparkle-tools/bin"}
ARCHIVE="$ROOT/dist/SplashFinish-${MARKETING_VERSION}-universal.zip"
ACCOUNT=io.bobuk.splash-finish
EXPECTED='UgU/VhTFdMVMUUwDG2TYW+cvn6ruGpfsdI82c02GdrA='
[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/generate_keys" ]] || {
  echo 'Sparkle tools missing: set SPARKLE_BIN to the verified Sparkle 2.10.1 bin directory.' >&2; exit 1;
}
[[ -f "$ARCHIVE" ]] || { echo "Missing $ARCHIVE" >&2; exit 1; }
ACTUAL=$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Sparkle Keychain public key mismatch; refusing to create an unusable appcast.' >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/splash-appcast.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$ARCHIVE" "$TMP/"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/bobuk-io/splash-finish/releases/download/v${MARKETING_VERSION}/" "$TMP"
[[ -f "$TMP/appcast.xml" ]] || { echo 'No appcast was generated' >&2; exit 1; }
cp "$TMP/appcast.xml" "$ROOT/dist/appcast.xml"
echo "Created $ROOT/dist/appcast.xml. Upload it with the ZIP and SHA256SUMS to release v${MARKETING_VERSION}."
