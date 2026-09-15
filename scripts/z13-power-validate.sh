#!/bin/bash
# Validate the battery-keyed power-profile fix on the ROG Flow Z13.
#
# Records the signals that revealed the AC0 flapping bug, so a charge cycle can
# be compared against the known-bad baseline (205 debounce invocations and 101
# Wi-Fi power-save toggles in 14 minutes while charging).
#
# Usage:
#   ./z13-power-validate.sh start     # begin recording (background)
#   ./z13-power-validate.sh status    # show current counts
#   ./z13-power-validate.sh stop      # stop and print a report
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

# Count udev-driven invocations in the journal since the monitor started.
# Scoping to the window matters: a per-boot count is cumulative and would
# include the pre-fix storm, making the report meaningless. An epoch marker is
# used rather than a wall-clock string so the window survives midnight rollover.
count_since_start() {
  local pattern="$1" since
  since=$(cat "$STARTFILE" 2>/dev/null || echo 0)
  journalctl -b --since "@${since}" --no-pager 2>/dev/null | grep -c "$pattern" || true
}
count_debounce() { count_since_start "omarchy-powerprofiles-set-debounced"; }
count_wifi() { count_since_start "z13-wifi-powersave-auto"; }

sample_once() {
  local ts ac0 bat_status bat_cap profile gov
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  ac0=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)
  bat_status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)
  bat_cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)
  profile=$(powerprofilesctl get 2>/dev/null || echo n/a)
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
  printf '%s ac0=%s bat_status=%s bat_cap=%s profile=%s gov=%s\n' \
    "$ts" "$ac0" "$bat_status" "$bat_cap" "$profile" "$gov" >> "$SAMPLES"
}

monitor_loop() {
  local prev_ac0="" prev_status="" prev_profile="" prev_gov=""
  while :; do
    sample_once
    local ac0 status profile gov
    ac0=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)
    status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)
    profile=$(powerprofilesctl get 2>/dev/null || echo n/a)
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)

    if [[ -n $prev_ac0 && $ac0 != "$prev_ac0" ]]; then
      printf '%s EVENT ac0 %s->%s (bat_status=%s)\n' "$(date '+%H:%M:%S')" "$prev_ac0" "$ac0" "$status" >> "$EVENTS"
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

    prev_ac0="$ac0"; prev_status="$status"; prev_profile="$profile"; prev_gov="$gov"
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
  echo "Now: unplug power, wait, plug it back in, and charge through the flap zone."
  echo "Then run: $0 stop"
}

cmd_status() {
  echo "=== now ==="
  printf 'AC0 online:   %s\n' "$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)"
  printf 'BAT0 status:  %s\n' "$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)"
  printf 'BAT0 capacity:%s%%\n' "$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)"
  printf 'profile:      %s\n' "$(powerprofilesctl get 2>/dev/null || echo n/a)"
  printf 'governor:     %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo
  echo "=== since monitor start (journal counts) ==="
  printf 'debounce invocations: %s\n' "$(count_debounce)"
  printf 'wifi-powersave runs:  %s\n' "$(count_wifi)"
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
  echo "--- power transitions observed ---"
  grep "EVENT bat_status" "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- profile changes ---"
  grep "EVENT profile" "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- governor changes ---"
  grep "EVENT governor" "$EVENTS" 2>/dev/null || echo "(none)"
  echo
  echo "--- AC0 transitions (informational; must NOT drive actions) ---"
  local flaps
  flaps=$(grep -c "EVENT ac0" "$EVENTS" 2>/dev/null) || flaps=0
  echo "count: $flaps"
  grep "EVENT ac0" "$EVENTS" 2>/dev/null | head -10 || true
  echo
  echo "--- udev rule invocations (since monitor start) ---"
  printf 'debounce:        %s\n' "$(count_debounce)"
  printf 'wifi-powersave:  %s\n' "$(count_wifi)"
  echo
  echo "=========================================================="
  echo " BASELINE (pre-fix, 20:36-20:50 while charging)"
  echo "=========================================================="
  echo "debounce invocations: 205 in 14 min"
  echo "wifi-powersave runs:  101 in 14 min"
  echo "profile flips:        governor oscillated performance <-> powersave"
  echo
  echo "PASS criteria: profile and governor change only on real power"
  echo "transitions; AC0 may still flap but must not cause actions."
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
