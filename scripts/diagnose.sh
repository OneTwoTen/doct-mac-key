#!/usr/bin/env bash
# DoctKey diagnostics: run this after logging out/in if the input source does not
# show up in System Settings. It never changes anything on the system.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== macOS ==="
sw_vers
echo

echo "=== installed app ==="
for APP in "/Library/Input Methods/DoctKey.app" "$HOME/Library/Input Methods/DoctKey.app"; do
  if [[ -d "$APP" ]]; then
    echo "found: $APP"
    codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Format" || true
    plutil -lint "$APP/Contents/Info.plist" || true
  else
    echo "missing: $APP"
  fi
done
echo

echo "=== running process ==="
pgrep -fl DoctKey || echo "(DoctKey is not running; it starts when the input source is selected or the app is opened)"
echo

echo "=== TIS input sources ==="
BIN="/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey"
[[ -x "$BIN" ]] || BIN="$HOME/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey"
[[ -x "$BIN" ]] || BIN="$ROOT/build/DoctKey.app/Contents/MacOS/DoctKey"
if [[ -x "$BIN" ]]; then
  # --print-status only reads the TIS database. The standalone helper also
  # registers, enables and selects the source, so it must not run in diagnostics.
  "$BIN" --print-status 2>&1 | tail -10
else
  echo "(app binary not found)"
fi
echo

echo "=== config ==="
if [[ -f "$HOME/.config/doctkey/config.json" ]]; then
  cat "$HOME/.config/doctkey/config.json"
else
  echo "(no config yet; created on first launch)"
fi
