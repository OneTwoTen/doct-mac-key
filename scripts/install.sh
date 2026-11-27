#!/usr/bin/env bash
# Install DoctKey as a macOS input source.
#
# macOS 26 (Tahoe) no longer discovers input methods copied to
# ~/Library/Input Methods; the system-wide /Library/Input Methods is used
# instead (the same location Squirrel uses on Tahoe). Older macOS keeps the
# per-user location.
#
# Set SIGN_ID="Apple Development: Your Name (TEAMID)" (or a Developer ID) to
# sign with a real identity; otherwise an ad-hoc signature is used.
#
# This script does not switch the current input source to DoctKey.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP="$ROOT/build/DoctKey.app"
# Explicit SIGN_ID wins; otherwise sign with the first Apple-issued code-signing
# identity in the keychain (Apple Development / Developer ID), because macOS 26
# rejects ad-hoc signed input methods. Falls back to ad-hoc when no identity.
SIGN_ID="${SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple Development|Developer ID Application): [^"]*"' \
    | head -1 | tr -d '"')"
fi

echo "==> building"
"$ROOT/scripts/build.sh"

if [[ ! -d "$BUILD_APP" ]]; then
  echo "error: build did not produce $BUILD_APP" >&2
  exit 1
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "==> signing with identity: $SIGN_ID"
  codesign --force --deep --options runtime --sign "$SIGN_ID" "$BUILD_APP"
else
  echo "==> ad-hoc signature (set SIGN_ID=\"Apple Development: ...\" to sign with an identity)"
fi

# Run a shell command as root: plain sudo when available (interactive terminal),
# otherwise the GUI administrator dialog via osascript.
run_privileged_shell() {
  local script="$1"
  if sudo -n true 2>/dev/null; then
    sudo /bin/sh -c "$script"
  else
    local escaped
    escaped="$(printf '%s' "$script" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    osascript -e "do shell script \"$escaped\" with administrator privileges"
  fi
}

echo "==> quitting running DoctKey"
pkill -x DoctKey 2>/dev/null || true
# Give the process a moment to release its IMKServer connection.
sleep 0.3

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"

# Target directory:
#   * TARGET_DIR env override wins (absolute path),
#   * macOS 26+ uses the system-wide "/Library/Input Methods" (root-owned, so
#     only administrators can add input methods),
#   * older macOS uses the per-user "~/Library/Input Methods".
if [[ -n "${TARGET_DIR:-}" ]]; then
  case "$TARGET_DIR" in
    /*) ;;
    *) echo "error: TARGET_DIR must be an absolute path" >&2; exit 1 ;;
  esac
  echo "==> using TARGET_DIR override: $TARGET_DIR"
elif [[ "$OS_MAJOR" -ge 26 ]]; then
  TARGET_DIR="/Library/Input Methods"
else
  TARGET_DIR="$HOME/Library/Input Methods"
fi
APP_DEST="$TARGET_DIR/DoctKey.app"

if [[ "$TARGET_DIR" == /Library/* ]]; then
  echo "==> macOS $OS_VERSION: installing system-wide to $TARGET_DIR (administrator required)"
  run_privileged_shell "mkdir -p $(printf '%q' "$TARGET_DIR") && rm -rf $(printf '%q' "$APP_DEST") && cp -R $(printf '%q' "$BUILD_APP") $(printf '%q' "$APP_DEST") && chown -R root:wheel $(printf '%q' "$APP_DEST") && chmod -R go+rX $(printf '%q' "$APP_DEST")"
else
  echo "==> macOS $OS_VERSION: installing to $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  rm -rf "$APP_DEST"
  cp -R "$BUILD_APP" "$APP_DEST"
  if [[ -n "$SIGN_ID" ]]; then
    codesign --force --deep --sign "$SIGN_ID" "$APP_DEST"
  else
    codesign --force --sign - "$APP_DEST"
  fi
fi

echo "==> installed: $APP_DEST"

if ! codesign --verify --strict "$APP_DEST" 2>/dev/null; then
  echo "warning: code-signature verification failed for $APP_DEST"
fi
if ! plutil -lint "$APP_DEST/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: installed Info.plist is invalid" >&2
  exit 1
fi

# Register/enable from the installed app itself: on macOS 26 this is the only
# reliable way to get the input source into the TIS database.
APP_BIN="$APP_DEST/Contents/MacOS/DoctKey"
if [[ -x "$APP_BIN" ]]; then
  set +e
  echo "==> registering input source (best effort)"
  "$APP_BIN" --register-input-source
  REGISTER_STATUS=$?

  echo "==> enabling input source (best effort)"
  "$APP_BIN" --enable-input-source
  ENABLE_STATUS=$?

  echo "==> current input-source status"
  "$APP_BIN" --print-status
  set -e

  echo "(register exit=$REGISTER_STATUS, enable exit=$ENABLE_STATUS; failures here are"
  echo " usually resolved by logging out and in and re-running the register step)"
fi

cat <<EOF

Installed DoctKey.app at:
  $APP_DEST

Next steps:
  1. Log out and back in (required on macOS 26 so the input source appears).
  2. System Settings -> Keyboard -> Text Input -> Input Sources -> Edit...
     Press "+", search "DoctKey" (or Vietnamese), select it and click Add.
  3. Switch with Ctrl+Space (or your input-source shortcut).
     The menu bar shows VI (Vietnamese) or EN (English).

Hotkeys:
  Ctrl+Opt+V  Vietnamese / English      Ctrl+Opt+T  Telex / VNI
  Ctrl+Opt+D  tone placement style      Ctrl+Opt+E  smart English
  Ctrl+Opt+R  reload ~/.config/doctkey/config.json

Config: ~/.config/doctkey/config.json

Troubleshooting:
  "$ROOT/scripts/enable-input-source.swift --path \"$APP_DEST\""
  If registration still fails, log out/in and run:
  "$APP_BIN --register-input-source"

Uninstall: scripts/uninstall.sh
EOF
