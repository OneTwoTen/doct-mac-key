#!/usr/bin/env bash
# Uninstall DoctKey: quit it, remove the installed bundle(s) and the config dir.
# Handles both the macOS 26 system-wide location and the older per-user one.
# The input-source entry itself must be removed in System Settings.
set -euo pipefail

CONFIG_DIR="$HOME/.config/doctkey"
APP_NAME="DoctKey.app"

echo "==> quitting DoctKey"
pkill -x DoctKey 2>/dev/null || true
sleep 0.3

remove_app() {
  local dest="$1"
  if [[ ! -d "$dest" ]]; then
    echo "==> not installed: $dest (skipped)"
    return
  fi
  case "$dest" in
    /Library/*)
      echo "==> removing (sudo): $dest"
      sudo rm -rf "$dest"
      ;;
    *)
      echo "==> removing: $dest"
      rm -rf "$dest"
      ;;
  esac
}

remove_app "/Library/Input Methods/$APP_NAME"
remove_app "$HOME/Library/Input Methods/$APP_NAME"

if [[ -d "$CONFIG_DIR" ]]; then
  echo "==> removing $CONFIG_DIR"
  rm -rf "$CONFIG_DIR"
else
  echo "==> $CONFIG_DIR not present (skipped)"
fi

cat <<'EOF'

Uninstalled DoctKey.

Manual cleanup (input-source entry):
  1. System Settings -> Keyboard -> Text Input -> Input Sources -> Edit...
  2. Select "DoctKey" and click the "−" button.
  3. Some macOS versions need a logout/login for the entry to disappear.
  4. If it stays listed, log out and back in, then repeat step 1.

Uninstalled.
EOF
