#!/usr/bin/env bash
# Publish an already built, signed and notarized release to GitHub.
# Run Scripts/release.sh --notarize KEYCHAIN_PROFILE and Scripts/make_appcast.sh first.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
REPOSITORY=bobuk-io/splash-finish
TAG="v${MARKETING_VERSION}"
ZIP="dist/SplashFinish-${MARKETING_VERSION}-universal.zip"
SUMS="dist/SHA256SUMS"
APPCAST="dist/appcast.xml"

for file in "$ZIP" "$SUMS" "$APPCAST"; do
  [[ -f "$file" ]] || {
    echo "Missing $file. Run Scripts/release.sh --notarize … and Scripts/make_appcast.sh first." >&2
    exit 1
  }
done
command -v gh >/dev/null || { echo "The GitHub CLI (gh) is required." >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || { echo "Commit changes before publishing." >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git ls-remote origin refs/heads/main | cut -f1)
[[ "$COMMIT" == "$REMOTE_COMMIT" ]] || { echo "Push the release commit to main before publishing." >&2; exit 1; }

# Fail closed if the published feed cannot be checked.
FEED=$(curl -fsSL --max-time 30 "https://github.com/${REPOSITORY}/releases/latest/download/appcast.xml")
PUBLISHED=$(printf '%s' "$FEED" | grep -o 'sparkle:version>[0-9]*<' | head -1 | tr -dc '0-9')
[[ -n "$PUBLISHED" ]] || { echo "Cannot read published build number." >&2; exit 1; }
if [[ "$BUILD_NUMBER" -le "$PUBLISHED" ]]; then
  echo "BUILD_NUMBER=$BUILD_NUMBER must be greater than the published $PUBLISHED." >&2
  exit 1
fi
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi

# Upload all assets while hidden so Sparkle never observes an incomplete release.
(cd dist && shasum -a 256 -c SHA256SUMS)
gh release create "$TAG" --repo "$REPOSITORY" --target "$COMMIT" --draft \
  --title "Splash Finish ${MARKETING_VERSION}" --generate-notes \
  "$ZIP" "$SUMS" "$APPCAST"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
echo "Published $TAG. Sparkle clients will see it through releases/latest/download/appcast.xml."
