#!/bin/bash
# Post-update hook: re-apply debounced power profile udev rule if Omarchy overwrote it.
# The Z13 generates spurious power_supply events that cause fan stops and notification
# spam. Our debounced wrapper fixes this, but Omarchy migrations can overwrite the udev
# rule. This hook patches it back after every omarchy update.

RULE="/etc/udev/rules.d/99-power-profile.rules"

if [[ -f "$RULE" ]]; then
    needs_reload=0

    # Patch the script path back to debounced if Omarchy restored the original
    if ! grep -q 'debounced' "$RULE" 2>/dev/null; then
        echo "Re-applying debounced power profile udev rule..."
        sudo sed -i 's|omarchy-powerprofiles-set"|omarchy-powerprofiles-set-debounced"|g' "$RULE"
        needs_reload=1
    fi

    # Strip the fixed --unit name if Omarchy restored it — collisions at boot
    # kill concurrent invocations, so the debounce script never runs.
    if grep -q '\-\-unit=omarchy-power-profile' "$RULE" 2>/dev/null; then
        echo "Removing fixed --unit from udev rule (prevents boot-time collisions)..."
        sudo sed -i 's| --unit=omarchy-power-profile||g' "$RULE"
        needs_reload=1
    fi

    if [[ $needs_reload -eq 1 ]]; then
        sudo udevadm control --reload-rules 2>/dev/null
        echo "Done."
    fi
fi
