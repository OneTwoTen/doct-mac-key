#!/usr/bin/env bash
# Build DoctKey.app: Rust static library + Swift InputMethodKit shell + bundle.
# Re-runnable; prints the artifact path on success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCES_DIR="$ROOT/macos/Sources"
RESOURCES_DIR="$ROOT/macos/Resources"
BRIDGING_HEADER="$SOURCES_DIR/Bridging.h"
INFO_PLIST="$RESOURCES_DIR/Info.plist"
ICON_SOURCE="$RESOURCES_DIR/DoctKeyIcon.pdf"
LIB_DIR="$ROOT/core/target/release"
LIB="$LIB_DIR/libdoctkey_core.a"
APP="$ROOT/build/DoctKey.app"
BINARY="$APP/Contents/MacOS/DoctKey"
APP_RESOURCES="$APP/Contents/Resources"

echo "==> cargo build --release"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"

if [[ ! -f "$LIB" ]]; then
  echo "error: Rust static library not found: $LIB" >&2
  exit 1
fi
if [[ ! -f "$BRIDGING_HEADER" ]]; then
  echo "error: bridging header not found: $BRIDGING_HEADER" >&2
  exit 1
fi
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist not found: $INFO_PLIST" >&2
  exit 1
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "error: icon source not found: $ICON_SOURCE" >&2
  exit 1
fi

echo "==> preparing $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES"

SWIFT_SOURCES=("$SOURCES_DIR"/*.swift)
if [[ ${#SWIFT_SOURCES[@]} -eq 0 ]]; then
  echo "error: no Swift sources in $SOURCES_DIR" >&2
  exit 1
fi

echo "==> swiftc -O (${#SWIFT_SOURCES[@]} sources)"
swiftc -O \
  -whole-module-optimization \
  -target arm64-apple-macos13.0 \
  -import-objc-header "$BRIDGING_HEADER" \
  -Xcc -I"$ROOT/core/include" \
  -Xlinker -dead_strip \
  "${SWIFT_SOURCES[@]}" \
  "$LIB" \
  -framework Cocoa -framework InputMethodKit -framework Carbon \
  -o "$BINARY"

echo "==> icon (PDF -> TIFF for the input-source menu)"
# tsInputMethodIconFileKey / tsInputMode*IconFileKey must point at real files in
# Contents/Resources. sips ships with macOS, so no extra tooling is needed.
sips -s format tiff -Z 128 "$ICON_SOURCE" --out "$APP_RESOURCES/DoctKeyIcon.tiff" >/dev/null
if [[ ! -s "$APP_RESOURCES/DoctKeyIcon.tiff" ]]; then
  echo "error: failed to generate $APP_RESOURCES/DoctKeyIcon.tiff" >&2
  exit 1
fi

cp "$INFO_PLIST" "$APP/Contents/Info.plist"
if [[ -n "${DOCTKEY_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DOCTKEY_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${DOCTKEY_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DOCTKEY_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sanity check: the icon files referenced by Info.plist must exist in the bundle.
if ! plutil -convert json -o - "$APP/Contents/Info.plist" | grep -q "DoctKeyIcon.tiff"; then
  echo "error: Info.plist does not reference DoctKeyIcon.tiff" >&2
  exit 1
fi
if [[ ! -f "$APP_RESOURCES/DoctKeyIcon.tiff" ]]; then
  echo "error: Info.plist references missing resource: DoctKeyIcon.tiff" >&2
  exit 1
fi

echo "==> strip local symbols"
strip -x "$BINARY"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> verifying bundle"
codesign --verify --strict "$APP"

echo ""
echo "Built: $APP"
echo "Executable: $BINARY"
echo "Install as an input source: scripts/install.sh"
