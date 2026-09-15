#!/bin/bash
# Post-update hook: re-apply the Z13 power-profile and Wi-Fi power-save udev
# rules if Omarchy overwrote them.
#
# Omarchy ships rules that key on ATTR{type}=="Mains" and ATTR{online}. On the
# ROG Flow Z13, AC0.online flaps 0 <-> 1 every 1-3 seconds while the battery is
# actively charging, which fires those rules continuously: profile switches,
# asusd fan curve rewrites (momentary fan stops), notification spam, and Wi-Fi
# power save toggling at the same rate.
#
# Our rules key on the system battery (KERNEL=="BAT*", type=Battery) instead,
# because BAT0.status reflects actual power flow and stays stable while AC0
# flaps. Omarchy migrations can restore the originals, so patch them back after
# every update.
#
# All pattern checks below inspect only lines beginning with SUBSYSTEM, never
# comments -- the rules carry explanatory comments that mention the very
# patterns being searched for, which would otherwise cause false positives and
# rewrite correct rules on every update.

set -u

PP_RULE="/etc/udev/rules.d/99-power-profile.rules"
WP_RULE="/etc/udev/rules.d/99-wifi-powersave.rules"
DEBOUNCE="$HOME/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced"
WIFI_WRAPPER="$HOME/.local/bin/z13-wifi-powersave-auto"

needs_reload=0

# Print only the active rule lines (SUBSYSTEM...) from a udev rules file.
rule_lines() { grep '^SUBSYSTEM' "$1" 2>/dev/null; }

# --- power profile rule -----------------------------------------------------
if [[ -f "$PP_RULE" ]]; then
    # Point at the debounced wrapper if Omarchy restored the plain script.
    if ! rule_lines "$PP_RULE" | grep -q 'debounced'; then
        echo "Re-applying debounced power profile udev rule..."
        sudo sed -i 's|omarchy-powerprofiles-set"|omarchy-powerprofiles-set-debounced"|g' "$PP_RULE"
        needs_reload=1
    fi

    # Re-key onto the battery if Omarchy restored the Mains-based triggers.
    if rule_lines "$PP_RULE" | grep -q 'ATTR{type}=="Mains"'; then
        echo "Re-keying power profile rule onto the system battery..."
        sudo tee "$PP_RULE" >/dev/null <<EOF
# Managed by ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh
# AC0.online flaps while charging on the Z13; key on BAT0.status instead.
SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{type}=="Battery", RUN+="/usr/bin/systemd-run --no-block --collect --property=After=power-profiles-daemon.service $DEBOUNCE"
EOF
        needs_reload=1
    fi

    # Strip the fixed --unit name if Omarchy restored it — collisions kill
    # concurrent invocations, so the debounce script never runs.
    if rule_lines "$PP_RULE" | grep -q 'unit=omarchy-power-profile'; then
        echo "Removing fixed --unit from udev rule (prevents boot-time collisions)..."
        sudo sed -i 's| --unit=omarchy-power-profile||g' "$PP_RULE"
        needs_reload=1
    fi
fi

# --- wifi powersave rule ----------------------------------------------------
# Re-key if Omarchy restored the Mains-based triggers, if the rule still matches
# ATTR{status} directly (which races the transition), or if it carries a fixed
# --unit name (which collides when BAT0 emits several uevents per transition).
if [[ -f "$WP_RULE" ]] \
    && { rule_lines "$WP_RULE" | grep -q 'ATTR{type}=="Mains"' \
        || rule_lines "$WP_RULE" | grep -q 'ATTR{status}' \
        || rule_lines "$WP_RULE" | grep -q 'unit=omarchy-wifi-powersave'; }; then
    echo "Re-keying wifi-powersave rule onto the system battery..."
    sudo tee "$WP_RULE" >/dev/null <<EOF
# Managed by ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh
# AC0.online flaps while charging on the Z13; key on BAT0.status instead.
# A single rule fires a wrapper that reads the settled status itself, because
# matching ATTR{status} directly in udev races the transition.
# No fixed --unit name: BAT0 emits several uevents per transition.
SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{type}=="Battery", RUN+="/usr/bin/systemd-run --no-block --collect $WIFI_WRAPPER"
EOF
    needs_reload=1
fi

if (( needs_reload )); then
    sudo udevadm control --reload-rules 2>/dev/null
    echo "Done."
fi
