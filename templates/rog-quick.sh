#!/bin/bash
# ROG Quick TDP — Super+Shift+Q
#
# Caps the APU power limit (SPL/SPPT/fPPT) below the firmware default (120W).
# The Z13's cooling sustains ~70-75W max; all profiles share the same firmware
# TDP ceiling, differing only in fan curves and CPU boost (EPP).
# Manual TDP caps are reset when switching profiles via Fn+F5.

PPT_DIR="/sys/devices/platform/asus-nb-wmi"

# Read current profile and PPT wattage
profile=$(asusctl profile get 2>/dev/null | sed -n 's/^Active profile: //p')
ppt_watts=$(sensors 2>/dev/null | grep -i ppt | awk '{print $2}' | cut -d. -f1)

selected=$(omarchy-menu-select "${profile} · ${ppt_watts}W" \
  "󰁝  Default (uncapped)" \
  "󰂃  15W — silent" \
  "󰂁  30W — light use" \
  "󰁿  45W — moderate" \
  "󰁽  70W — max sustained")

# Helper: set TDP via pkexec
set_tdp() {
  local spl=$1
  local sppt=$(( spl * 12 / 10 ))
  local fppt=$(( spl * 14 / 10 ))

  pkexec bash -c "
    echo $spl > $PPT_DIR/ppt_pl1_spl
    echo $sppt > $PPT_DIR/ppt_pl2_sppt
    echo $fppt > $PPT_DIR/ppt_fppt
    echo $sppt > $PPT_DIR/ppt_apu_sppt
    echo $sppt > $PPT_DIR/ppt_platform_sppt
  " && notify-send -u low -t 2000 "󱐋    TDP ${spl}W" "SPL=$spl  SPPT=$sppt  fPPT=$fppt"
}

case $selected in
  *Default*)
    profile=$(asusctl profile get 2>/dev/null | sed -n 's/^Active profile: //p')
    asusctl profile set "$profile" && notify-send -u low -t 2000 "󱐋    TDP Reset" "Restored $profile defaults" ;;
  *15W*) set_tdp 15 ;;
  *30W*) set_tdp 30 ;;
  *45W*) set_tdp 45 ;;
  *70W*) set_tdp 70 ;;
esac
