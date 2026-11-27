#!/usr/bin/env bash
# Build, sign, archive and publish a DoctKey version to public GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must use semantic version format (for example 0.2.1)" >&2
  exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is required to publish releases" >&2
  exit 1
fi
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: this source folder is not a Git repository" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: commit all source changes before publishing a release" >&2
  exit 1
fi

SIGN_ID="${SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple Development|Developer ID Application): [^"]*"' \
    | head -1 | tr -d '"' || true)"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "error: an Apple Development or Developer ID signing identity is required" >&2
  exit 1
fi

REPOSITORY="OneTwoTen/doct-mac-key"
TAG="v$VERSION"
APP="$ROOT/build/DoctKey.app"
ARCHIVE="$ROOT/build/DoctKey-$VERSION-macos-arm64.zip"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi

echo "==> building DoctKey $VERSION"
DOCTKEY_VERSION="$VERSION" DOCTKEY_BUILD_NUMBER="$VERSION" "$ROOT/scripts/build.sh"

echo "==> signing with $SIGN_ID"
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> creating $ARCHIVE"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

echo "==> publishing $TAG to $REPOSITORY"
gh release create "$TAG" "$ARCHIVE" \
  --repo "$REPOSITORY" \
  --title "DoctKey $VERSION" \
  --notes "DoctKey Vietnamese input method for macOS. This release is published outside the Apple App Store."

echo "Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
