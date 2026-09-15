#!/bin/bash
# Set Wi-Fi power save based on the system battery's actual power flow.
#
# Omarchy ships a udev rule keyed on ATTR{type}=="Mains", ATTR{online}. On the
# ROG Flow Z13, AC0.online flaps 0 <-> 1 every 1-3 seconds while the battery is
# charging, so Wi-Fi power save was toggled at the same rate (101 times in 14
# minutes) -- a plausible contributor to the Wi-Fi instability documented in
# docs/wifi-investigation-2026-03-08.md.
#
# Matching ATTR{status}=="Discharging" directly in the udev rule does not work
# either: the udev event fires before BAT0.status settles, so the rule is
# evaluated against a mid-transition value and can match the wrong branch.
#
# Instead a single udev rule fires this script on any BAT0 change, and the
# script reads the settled status itself. Same reasoning as
# omarchy-powerprofiles-set-debounced.
#
#   Discharging              -> power save on  (battery)
#   Charging / Not charging / Full -> power save off (AC)
#
# Unrecognised or unsettled readings are retried, then ignored.

set -u

INTERVAL=1
MAX_SAMPLES=8
STABLE_READS=2

find_system_battery() {
    local ps scope
    for ps in /sys/class/power_supply/*; do
        [[ -r $ps/type && -r $ps/status ]] || continue
        [[ $(cat "$ps/type") == Battery ]] || continue
        scope=$(cat "$ps/scope" 2>/dev/null || echo "")
        [[ $scope == Device ]] && continue
        printf '%s\n' "$ps"
        return 0
    done
    return 1
}

read_power_save() {
    local status
    status=$(cat "$1/status" 2>/dev/null) || return 1
    case "$status" in
        Discharging)                  echo on ;;
        Charging|"Not charging"|Full) echo off ;;
        *)                            return 1 ;;
    esac
}

bat=$(find_system_battery) || exit 0

# Poll until the status settles, so a mid-transition event still converges.
mode=""
prev=""
agree=0
for ((i = 0; i < MAX_SAMPLES; i++)); do
    if current=$(read_power_save "$bat"); then
        if [[ -n $prev && $current == "$prev" ]]; then
            agree=$((agree + 1))
            if (( agree >= STABLE_READS - 1 )); then
                mode="$current"
                break
            fi
        else
            agree=0
        fi
        prev="$current"
    else
        prev=""
        agree=0
    fi
    sleep "$INTERVAL"
done

[[ -n $mode ]] || exit 0

for iface in /sys/class/net/*/wireless; do
    [[ -e $iface ]] || continue
    iface=$(basename "$(dirname "$iface")")
    iw dev "$iface" set power_save "$mode" 2>/dev/null || true
done
