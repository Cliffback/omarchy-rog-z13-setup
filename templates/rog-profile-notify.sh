#!/bin/bash
# Watch asusd platform profile changes via dbus and show notification.
# Triggered by Fn+F5 (Armory Crate key) which cycles Quiet → Balanced → Performance.

NOTIFY_ID=0
LAST_PROFILE=""

send_notify() {
    NOTIFY_ID=$(notify-send -u low -t 2000 -r "$NOTIFY_ID" -p "$1")
}

dbus-monitor --system "type='signal',sender='xyz.ljones.Asusd',member='PropertiesChanged',path='/xyz/ljones'" 2>/dev/null |
while read -r line; do
    if [[ "$line" == *"PlatformProfile"* ]]; then
        profile=$(cat /sys/firmware/acpi/platform_profile)
        # Only notify if profile actually changed
        if [[ "$profile" != "$LAST_PROFILE" ]]; then
            LAST_PROFILE="$profile"
            case "$profile" in
                quiet)       send_notify "󰌪    Quiet" ;;
                balanced)    send_notify "󰈈    Balanced" ;;
                performance) send_notify "󱐋    Performance" ;;
                *)           send_notify "    $profile" ;;
            esac
        fi
    fi
done
