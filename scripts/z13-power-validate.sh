#!/bin/bash
# Validate power-profile behaviour on the ROG Flow Z13.
#
# Originally written to prove the Omarchy 3 AC0 flapping bug and the battery-keyed
# fix for it. Omarchy 4 (Quattro) deleted that udev rule and moved profile
# switching into Quickshell, which watches UPower.onBattery — a property derived
# from the same AC line power that flaps. This script now measures whether the
# new mechanism inherits the bug, and whether any flap still costs anything
# (asusd rewrites the fan curve on every platform-profile change).
#
# Usage:
#   ./z13-power-validate.sh start     # begin recording (background)
#   ./z13-power-validate.sh status    # show current counts
#   ./z13-power-validate.sh stop      # stop and print a report + verdict
#
# Or run in the foreground and Ctrl-C when done:
#   ./z13-power-validate.sh watch
set -euo pipefail

STATE_DIR="${HOME}/.local/state/z13-power-validate"
SAMPLES="${STATE_DIR}/samples.log"
EVENTS="${STATE_DIR}/events.log"
PIDFILE="${STATE_DIR}/monitor.pid"
STARTFILE="${STATE_DIR}/start.epoch"
INTERVAL="${INTERVAL:-1}"

mkdir -p "$STATE_DIR"

# Count journal lines matching a pattern since the monitor started.
# Scoping to the window matters: a per-boot count is cumulative and would
# include unrelated activity, making the report meaningless. An epoch marker is
# used rather than a wall-clock string so the window survives midnight rollover.
count_since_start() {
  local pattern="$1" since
  since=$(cat "$STARTFILE" 2>/dev/null || echo 0)
  journalctl -b --since "@${since}" --no-pager 2>/dev/null | grep -c "$pattern" || true
}

# asusd rewrites the fan curve on every platform-profile change. That is the
# real cost of churn: a momentary fan stop plus notification noise. Counting it
# separates "the signal flapped" from "the flap did anything".
count_fan_curves() { count_since_start "write_profile_curve_to_platform"; }

# Omarchy 4 moves profile switching into Quickshell (UPower.onBatteryChanged ->
# omarchy-powerprofiles-set). Neither PPD nor the shell logs the call, so this is
# best-effort evidence only; the authoritative signal is the sampled profile and
# UPower.onBattery transitions below.
count_ppd() { count_since_start "omarchy-powerprofiles-set"; }

# UPower's OnBattery property is what Quickshell's battery service watches. It is
# derived from the AC line power, the same source that flaps on this machine, so
# it is the signal that decides whether the Omarchy 4 mechanism inherits the bug.
read_upower() {
  busctl get-property org.freedesktop.UPower /org/freedesktop/UPower \
    org.freedesktop.UPower OnBattery 2>/dev/null | awk '{print $2}' || echo n/a
}

# Count matching lines in the event log. grep -c prints its count and exits 1
# when the count is zero, so the exit status must be swallowed without appending
# a second value to the output.
count_events() {
  [[ -f $EVENTS ]] || { echo 0; return; }
  grep -c "$1" "$EVENTS" 2>/dev/null || true
}

sample_once() {
  local ts ac0 bat_status bat_cap profile gov upower
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  ac0=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)
  bat_status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)
  bat_cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)
  profile=$(powerprofilesctl get 2>/dev/null || echo n/a)
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
  upower=$(read_upower)
  printf '%s ac0=%s bat_status=%s bat_cap=%s profile=%s gov=%s upower=%s\n' \
    "$ts" "$ac0" "$bat_status" "$bat_cap" "$profile" "$gov" "$upower" >> "$SAMPLES"
}

monitor_loop() {
  local prev_ac0="" prev_status="" prev_profile="" prev_gov="" prev_upower=""
  while :; do
    sample_once
    local ac0 status profile gov upower
    ac0=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)
    status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)
    profile=$(powerprofilesctl get 2>/dev/null || echo n/a)
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
    upower=$(read_upower)

    if [[ -n $prev_ac0 && $ac0 != "$prev_ac0" ]]; then
      printf '%s EVENT ac0 %s->%s (bat_status=%s)\n' "$(date '+%H:%M:%S')" "$prev_ac0" "$ac0" "$status" >> "$EVENTS"
      if [[ $status == "$prev_status" ]]; then
        printf '%s EVENT ac0-flap %s->%s (bat_status=%s unchanged)\n' "$(date '+%H:%M:%S')" "$prev_ac0" "$ac0" "$status" >> "$EVENTS"
      fi
    fi
    if [[ -n $prev_status && $status != "$prev_status" ]]; then
      printf '%s EVENT bat_status %s->%s\n' "$(date '+%H:%M:%S')" "$prev_status" "$status" >> "$EVENTS"
    fi
    if [[ -n $prev_profile && $profile != "$prev_profile" ]]; then
      printf '%s EVENT profile %s->%s\n' "$(date '+%H:%M:%S')" "$prev_profile" "$profile" >> "$EVENTS"
    fi
    if [[ -n $prev_gov && $gov != "$prev_gov" ]]; then
      printf '%s EVENT governor %s->%s\n' "$(date '+%H:%M:%S')" "$prev_gov" "$gov" >> "$EVENTS"
    fi
    if [[ -n $prev_upower && $upower != "$prev_upower" ]]; then
      printf '%s EVENT upower %s->%s (ac0=%s bat_status=%s)\n' "$(date '+%H:%M:%S')" "$prev_upower" "$upower" "$ac0" "$status" >> "$EVENTS"
      # A flap is an AC-line transition that is NOT accompanied by a change in
      # actual power flow. A real plug/unplug moves both AC0/UPower and
      # BAT0.status in the same tick; the original bug toggled AC0 every 1-3s
      # while BAT0.status stayed "Charging" throughout. Counting only the
      # unpaired transitions is what separates "the user plugged in" from
      # "the signal flapped", and it is the number the verdict keys on.
      if [[ $status == "$prev_status" ]]; then
        printf '%s EVENT upower-flap %s->%s (bat_status=%s unchanged)\n' "$(date '+%H:%M:%S')" "$prev_upower" "$upower" "$status" >> "$EVENTS"
      fi
    fi

    prev_ac0="$ac0"; prev_status="$status"; prev_profile="$profile"; prev_gov="$gov"; prev_upower="$upower"
    sleep "$INTERVAL"
  done
}

cmd_start() {
  if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  : > "$SAMPLES"; : > "$EVENTS"
  date +%s > "$STARTFILE"
  nohup "$0" _loop >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  echo "started (pid $(cat "$PIDFILE"))"
  echo "samples: $SAMPLES"
  echo "events:  $EVENTS"
  echo
  echo "Now: leave it on battery briefly for a baseline, then plug in and charge"
  echo "through the flap zone. Then run: $0 stop"
}

cmd_status() {
  echo "=== now ==="
  printf 'AC0 online:    %s\n' "$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)"
  printf 'BAT0 status:   %s\n' "$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)"
  printf 'BAT0 capacity: %s%%\n' "$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)"
  printf 'profile:       %s\n' "$(powerprofilesctl get 2>/dev/null || echo n/a)"
  printf 'governor:      %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  printf 'UPower.onBattery: %s\n' "$(read_upower)"
  echo
  echo "=== since monitor start ==="
  printf 'UPower.onBattery changes: %s\n' "$(count_events 'EVENT upower ')"
  printf 'AC0 toggles:              %s\n' "$(count_events 'EVENT ac0 ')"
  printf 'unpaired AC-line flaps:   %s\n' "$(( $(count_events 'EVENT upower-flap') + $(count_events 'EVENT ac0-flap') ))"
  printf 'profile changes:          %s\n' "$(count_events 'EVENT profile')"
  printf 'governor changes:         %s\n' "$(count_events 'EVENT governor')"
  printf 'asusd fan-curve writes:   %s\n' "$(count_fan_curves)"
  echo
  if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "monitor: running (pid $(cat "$PIDFILE"))"
    echo "samples recorded: $(wc -l < "$SAMPLES" 2>/dev/null || echo 0)"
    echo "events recorded:  $(wc -l < "$EVENTS" 2>/dev/null || echo 0)"
  else
    echo "monitor: not running"
  fi
}

cmd_stop() {
  if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  sleep 1

  local start_epoch end_epoch duration
  start_epoch=$(cat "$STARTFILE" 2>/dev/null || echo 0)
  end_epoch=$(date +%s)
  duration=$(( end_epoch - start_epoch ))
  [[ $start_epoch -eq 0 ]] && duration=0

  echo "=========================================================="
  echo " VALIDATION REPORT"
  echo "=========================================================="
  printf 'window:  %s -> %s (%dm%02ds)\n' \
    "$(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" \
    "$(date -d "@$end_epoch" '+%Y-%m-%d %H:%M:%S')" \
    "$((duration / 60))" "$((duration % 60))"
  echo "samples: $(wc -l < "$SAMPLES" 2>/dev/null || echo 0)"
  echo
  echo "--- UPower.onBattery transitions (what Quickshell reacts to) ---"
  local upower_changes upower_flaps ac0_flaps ac0_changes profile_changes gov_changes fan_curves
  upower_changes=$(count_events 'EVENT upower ')
  upower_flaps=$(count_events 'EVENT upower-flap')
  echo "count: $upower_changes (unpaired flaps: $upower_flaps)"
  grep 'EVENT upower ' "$EVENTS" 2>/dev/null | head -10 || true
  echo
  echo "--- profile changes ---"
  profile_changes=$(count_events 'EVENT profile')
  echo "count: $profile_changes"
  grep 'EVENT profile' "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- governor changes ---"
  gov_changes=$(count_events 'EVENT governor')
  echo "count: $gov_changes"
  grep 'EVENT governor' "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- AC0 transitions (informational; must NOT drive actions) ---"
  ac0_changes=$(count_events 'EVENT ac0 ')
  ac0_flaps=$(count_events 'EVENT ac0-flap')
  echo "count: $ac0_changes (unpaired flaps: $ac0_flaps)"
  grep 'EVENT ac0 ' "$EVENTS" 2>/dev/null | head -10 || true
  echo
  echo "--- battery status transitions ---"
  grep 'EVENT bat_status' "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- asusd fan-curve writes (impact: fan stop + notification noise) ---"
  fan_curves=$(count_fan_curves)
  echo "count: $fan_curves"
  echo
  echo "--- omarchy-powerprofiles-set invocations (best effort; not logged) ---"
  echo "count: $(count_ppd)"
  echo
  echo "=========================================================="
  echo " VERDICT"
  echo "=========================================================="
  # The decisive signal is an UNPAIRED AC-line transition: one that is not
  # accompanied by a change in BAT0.status. A real plug/unplug moves both; the
  # original bug toggled AC0/UPower every 1-3s while BAT0.status stayed put.
  # Keying on unpaired transitions is what makes "the user plugged in once"
  # read as healthy rather than as churn.
  local total_flaps=$(( upower_flaps + ac0_flaps ))
  if (( total_flaps == 0 )); then
    echo "No unpaired AC-line transitions: every AC0/UPower change was matched by a"
    echo "BAT0.status change, i.e. real plug/unplug events only."
    echo "-> The Omarchy 4 mechanism does not inherit the AC0 flap."
    echo "-> Remove the debounce machinery; keep nothing."
  elif (( profile_changes <= 2 )); then
    echo "AC line flapped unpaired ($total_flaps times) but the profile held"
    echo "($profile_changes changes)."
    echo "-> Quickshell fires, but the result is idempotent. No action needed."
    echo "-> Remove the debounce machinery; keep nothing."
  else
    echo "AC line flapped unpaired ($total_flaps times) AND the profile churned"
    echo "($profile_changes changes, $fan_curves fan-curve writes)."
    echo "-> Churn is real under Omarchy 4. Rebuild safely: disable the omarchy.battery"
    echo "   plugin and use a user-level watcher keyed on BAT0.status (no root, no RUN+=)."
  fi
  echo
  echo "=========================================================="
  echo " BASELINE (pre-fix, 20:36-20:50 while charging, Omarchy 3)"
  echo "=========================================================="
  echo "debounce invocations: 205 in 14 min"
  echo "wifi-powersave runs:  101 in 14 min"
  echo "profile flips:        governor oscillated performance <-> powersave"
  echo
  echo "=========================================================="
  echo " RESULT (2026-09-16, Omarchy 4 Quattro, 36% -> 90% charge)"
  echo "=========================================================="
  echo "unpaired AC-line flaps: 0 (AC0 and UPower each moved once, at plug-in)"
  echo "profile changes:        1 at plug-in + DeckShift restore writes"
  echo "debounce machinery:     removed (mechanism moved into Quickshell)"
}

case "${1:-}" in
  start) cmd_start ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  _loop) monitor_loop ;;
  watch)
    : > "$SAMPLES"; : > "$EVENTS"
    date +%s > "$STARTFILE"
    echo "watching; Ctrl-C to stop"
    trap 'cmd_stop; exit 0' INT
    monitor_loop
    ;;
  *)
    echo "usage: $0 {start|status|stop|watch}" >&2
    exit 1
    ;;
esac
