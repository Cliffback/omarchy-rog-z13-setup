#!/bin/bash
# ASUS ROG Flow Z13 (2025) — Touchpad Reset on Resume
# The AMD xHCI controller intermittently crashes during resume, causing the
# ELAN touchpad firmware in the keyboard dock to re-enumerate with corrupted
# multi-touch state (gestures require +1 finger). This hook forces a clean
# USB reinitialization after every resume.
#
# USB ID: 0b05:1a30 (ASUSTeK GZ302EA-Keyboard)

case "$1" in
  post)
    for dev in /sys/bus/usb/devices/*; do
      if [[ -f "$dev/idVendor" ]] \
         && [[ "$(cat "$dev/idVendor")" == "0b05" ]] \
         && [[ "$(cat "$dev/idProduct")" == "1a30" ]]; then
        echo 0 > "$dev/authorized"
        sleep 1
        echo 1 > "$dev/authorized"
        logger -t z13-touchpad-reset "Reset ASUS keyboard dock $(basename "$dev")"
      fi
    done
    ;;
esac
