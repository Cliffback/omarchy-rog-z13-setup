#!/bin/bash
set -euo pipefail

# Patch omarchy to save/restore keyboard backlight across suspend/resume.
#
# The issue: hypridle's before_sleep_cmd uses OMARCHY_LOCK_ONLY=true which
# skips omarchy-brightness-keyboard off (the save step). On resume,
# omarchy-brightness-keyboard restore has no saved state, so the backlight
# is not restored after suspend.
#
# Fix:
# 1. Add 'save' command to omarchy-brightness-keyboard (saves brightness
#    without changing it)
# 2. Call 'save' from omarchy-system-lock in LOCK_ONLY mode (before suspend)
#
# See: https://github.com/basecamp/omarchy/pull/5839

KEYBOARD="$HOME/.local/share/omarchy/bin/omarchy-brightness-keyboard"
LOCK="$HOME/.local/share/omarchy/bin/omarchy-system-lock"

patched=0

# --- Patch 1: Add 'save' command to omarchy-brightness-keyboard ---

if [[ ! -f "$KEYBOARD" ]]; then
    echo "ERROR: $KEYBOARD not found" >&2
    exit 1
fi

if grep -q 'direction == "save"' "$KEYBOARD"; then
    echo "[keyboard] Already patched."
else
    # Add 'save' command before the 'restore' block.
    sed -i '/direction == "restore"/i \
elif [[ $direction == "save" ]]; then\
  # Save current brightness without changing it (used before suspend).\
  current=$(brightnessctl -d "$device" get)\
  brightnessctl -sd "$device" set "$current" >/dev/null\
  exit 0' "$KEYBOARD"

    # Update args comment
    sed -i 's/args=<up|down|cycle|off|restore>/args=<up|down|cycle|off|save|restore>/' "$KEYBOARD"

    if grep -q 'direction == "save"' "$KEYBOARD"; then
        echo "[keyboard] Patched successfully."
        patched=1
    else
        echo "ERROR: Failed to patch $KEYBOARD" >&2
        exit 1
    fi
fi

# --- Patch 2: Save brightness in LOCK_ONLY mode in omarchy-system-lock ---

if [[ ! -f "$LOCK" ]]; then
    echo "ERROR: $LOCK not found" >&2
    exit 1
fi

if grep -q 'omarchy-brightness-keyboard save' "$LOCK"; then
    echo "[lock] Already patched."
else
    # Replace the closing 'fi' of the LOCK_ONLY block with an else branch.
    # Match the specific pattern at the end of the file.
    sed -i '/OMARCHY_LOCK_ONLY/,$ {
        /^fi$/c\else\
  omarchy-brightness-keyboard save\
fi
    }' "$LOCK"

    if grep -q 'omarchy-brightness-keyboard save' "$LOCK"; then
        echo "[lock] Patched successfully."
        patched=1
    else
        echo "ERROR: Failed to patch $LOCK" >&2
        exit 1
    fi
fi

if [[ $patched -eq 0 ]]; then
    echo "Nothing to patch — already up to date."
fi
