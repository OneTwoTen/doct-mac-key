#!/usr/bin/env bash
# Compile the Swift app sources (except main.swift) + the fixture runner against
# the real Rust core, then run every fixture in both insert modes.
# Exit code 0 only if all fixtures and all extra checks pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIB_DIR="$ROOT/core/target/release"
LIB="$LIB_DIR/libdoctkey_core.a"
BRIDGING_HEADER="$ROOT/macos/Sources/Bridging.h"

echo "==> building Rust static library"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"
if [[ ! -f "$LIB" ]]; then
  echo "error: Rust static library missing: $LIB" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doctkey-swift-tests.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

BINARY="$TEMP_DIR/doctkey-tests"

APP_SOURCES=()
for source in "$ROOT"/macos/Sources/*.swift; do
  if [[ "$(basename "$source")" == "main.swift" ]]; then
    continue
  fi
  APP_SOURCES+=("$source")
done

echo "==> compiling Swift fixture tests"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -import-objc-header "$BRIDGING_HEADER" \
  -Xcc -I"$ROOT/core/include" \
  "$ROOT/macos/Tests/main.swift" "$ROOT/macos/Tests/MockHost.swift" \
  "${APP_SOURCES[@]}" \
  "$LIB" \
  -framework Cocoa -framework InputMethodKit -framework Carbon \
  -o "$BINARY"

echo "==> running fixture tests"
set +e
"$BINARY"
STATUS=$?
set -e

exit "$STATUS"
