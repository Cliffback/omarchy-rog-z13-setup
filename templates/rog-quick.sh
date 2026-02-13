#!/bin/bash
# ROG Quick TDP — Super+A

PPT_DIR="/sys/devices/platform/asus-nb-wmi"

# Read current PPT wattage from sensors
ppt_watts=$(sensors 2>/dev/null | grep -i ppt | awk '{print $2}' | cut -d. -f1)

# TDP presets: SPL | SPPT (1.2x) | fPPT (1.4x, capped at 130)
#   15W:  15 /  18 /  21
#   30W:  30 /  36 /  42
#   45W:  45 /  54 /  63
#   70W:  70 /  84 /  98
#   90W:  90 / 108 / 126
#  120W: 120 / 130 / 130
tdp_presets="15 30 45 70 90 120"
tdp_labels=(
  "TDP 15W — max battery"
  "TDP 30W — light browsing"
  "TDP 45W — moderate tasks"
  "TDP 70W — default"
  "TDP 90W — gaming"
  "TDP 120W — max power"
)

# Build menu
options="Default\n"
i=0
for w in $tdp_presets; do
  options+="${tdp_labels[$i]}\n"
  ((i++))
done

# Remove trailing newline for rofi
options=${options%\\n}

selected=$(echo -e "$options" | rofi -dmenu -p "TDP ${ppt_watts}W")

# Helper: set TDP via pkexec
set_tdp() {
  local spl=$1
  local sppt=$(( spl * 12 / 10 ))
  local fppt=$(( spl * 14 / 10 ))
  # Cap SPPT and fPPT at 130W (APU/platform limit)
  [ "$sppt" -gt 130 ] && sppt=130
  [ "$fppt" -gt 130 ] && fppt=130

  pkexec bash -c "
    echo $spl > $PPT_DIR/ppt_pl1_spl
    echo $sppt > $PPT_DIR/ppt_pl2_sppt
    echo $fppt > $PPT_DIR/ppt_fppt
    echo $sppt > $PPT_DIR/ppt_apu_sppt
    echo $sppt > $PPT_DIR/ppt_platform_sppt
  " && notify-send "TDP" "${spl}W (SPL=$spl SPPT=$sppt fPPT=$fppt)"
}

case $selected in
  "Default"*)
    profile=$(asusctl profile -p 2>/dev/null | sed -n 's/^Active profile is //p')
    asusctl profile -P "$profile" && notify-send "TDP" "Reset to $profile defaults" ;;
  "TDP 15W"*) set_tdp 15 ;;
  "TDP 30W"*) set_tdp 30 ;;
  "TDP 45W"*) set_tdp 45 ;;
  "TDP 70W"*) set_tdp 70 ;;
  "TDP 90W"*) set_tdp 90 ;;
  "TDP 120W"*) set_tdp 120 ;;
esac
