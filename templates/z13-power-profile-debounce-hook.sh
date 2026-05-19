#!/bin/bash
# Post-update hook: re-apply debounced power profile udev rule if Omarchy overwrote it.
# The Z13 generates spurious power_supply events that cause fan stops and notification
# spam. Our debounced wrapper fixes this, but Omarchy migrations can overwrite the udev
# rule. This hook patches it back after every omarchy update.

RULE="/etc/udev/rules.d/99-power-profile.rules"

if [[ -f "$RULE" ]] && ! grep -q 'debounced' "$RULE" 2>/dev/null; then
    echo "Re-applying debounced power profile udev rule..."
    sudo sed -i 's|omarchy-powerprofiles-set"|omarchy-powerprofiles-set-debounced"|g' "$RULE"
    sudo udevadm control --reload-rules 2>/dev/null
    echo "Done."
fi
