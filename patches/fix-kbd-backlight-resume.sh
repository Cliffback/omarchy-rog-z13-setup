#!/bin/bash
set -euo pipefail

# Patch omarchy to save/restore keyboard backlight across suspend/resume/lock.
#
# Root cause (suspend): hypridle's before_sleep_cmd uses OMARCHY_LOCK_ONLY=true
# which skips saving keyboard brightness. On resume, restore has no saved state.
#
# Root cause (lock): omarchy-system-lock turns off the keyboard in a background
# subshell, bypassing hypridle's idle tracking. The keyboard only restores after
# entering the password, not when the lock screen wakes.
#
# Fix:
# 1. Add 'save' command to omarchy-brightness-keyboard (saves brightness
#    without changing it)
# 2. Replace 'off' with 'save' in omarchy-system-lock so keyboard stays lit
#    on lock screen, and brightness is saved for suspend/resume restore
# 3. Add 'save' in LOCK_ONLY path (before suspend)
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

# --- Patch 2: Replace 'off' with 'save' and add LOCK_ONLY save ---

if [[ ! -f "$LOCK" ]]; then
    echo "ERROR: $LOCK not found" >&2
    exit 1
fi

if grep -q 'omarchy-brightness-keyboard save' "$LOCK"; then
    echo "[lock] Already patched."
else
    # Replace 'off' with 'save' so keyboard stays lit on lock screen.
    sed -i 's/omarchy-brightness-keyboard off/omarchy-brightness-keyboard save/' "$LOCK"

    # Add else branch to save brightness in LOCK_ONLY mode (before suspend).
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
