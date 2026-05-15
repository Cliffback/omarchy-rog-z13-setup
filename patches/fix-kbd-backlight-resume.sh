#!/bin/bash
set -euo pipefail

# Patch omarchy-brightness-keyboard to not reset keyboard backlight to 0
# after suspend/resume when no saved brightness state exists.
#
# The issue: brightnessctl -rd defaults to 0 when no save file exists.
# After suspend, before_sleep_cmd uses OMARCHY_LOCK_ONLY=true which skips
# the save step, so on resume the backlight resets to 0.
#
# See: https://github.com/basecamp/omarchy/pull/5839

TARGET="$HOME/.local/share/omarchy/bin/omarchy-brightness-keyboard"

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: $TARGET not found" >&2
    exit 1
fi

if grep -q '/run/brightnessctl/' "$TARGET"; then
    echo "Already patched."
    exit 0
fi

# Replace the unconditional brightnessctl -rd with a save-file check.
sed -i '/direction == "restore"/,/exit 0/{
  s|brightnessctl -rd "\$device" >/dev/null|if [[ -f "/run/brightnessctl/$device/save" ]]; then\n    brightnessctl -rd "$device" >/dev/null\n  fi|
}' "$TARGET"

if grep -q '/run/brightnessctl/' "$TARGET"; then
    echo "Patched successfully: $TARGET"
else
    echo "ERROR: Patch failed" >&2
    exit 1
fi
