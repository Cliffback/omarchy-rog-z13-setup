#!/bin/bash
# Validate power-profile behaviour on the ROG Flow Z13.
#
# The EC toggles AC0.online spuriously while charging: a few flaps every few
# minutes near full charge, and under heavy load (BAT0.status and
# UPower.onBattery flap with it). Omarchy 4's battery service switched the
# platform profile on every UPower.onBattery change. The repo replaces it with
# z13.battery, which applies the switch only after onBattery has been stable for
# 5 s.
#
# Two distinct churn paths, and the report keeps them apart:
#   1. PROFILE churn — Quickshell reacts to onBattery. This is what z13.battery
#      debounces. Pass = ~0 profile changes.
#   2. FAN-CURVE churn — asusd rewrites the fan curve on every AC-line notify
#      ("External power supply state changed"), even when it does NOT change the
#      profile. The debounce cannot stop this; it scales with AC events, not
#      profile changes.
#
# Counting strategy: the authoritative AC-event count comes from the asusd
# journal, and profile/fan-curve counts from the journal too. The 1 s sampler is
# cheap sysfs-only (no process spawns) so it does not drift under load, and is
# kept for context and for pairing transitions with BAT0.status. A system-bus
# monitor is deliberately not used: `busctl monitor` on the system bus needs
# privileges (BecomeMonitor: Access denied), so it cannot run unprivileged.
#
# Usage:
#   ./z13-power-validate.sh start      # begin recording (background)
#   ./z13-power-validate.sh status     # show current counts
#   ./z13-power-validate.sh stop       # stop and print a report + verdict
#   ./z13-power-validate.sh watch      # foreground; Ctrl-C to report
#   ./z13-power-validate.sh loadtest [SECONDS] [THREADS]
#       # plugged in: run stress-ng for SECONDS (default 300) on THREADS
#       # (default: all CPUs) while recording, then report.
#   ./z13-power-validate.sh fanprobe [SECONDS] [THREADS]
#       # like loadtest, but also samples CPU/GPU fan RPM at ~10 Hz and reports
#       # whether asusd's fan-curve writes actually move the fans.
set -euo pipefail

STATE_DIR="${HOME}/.local/state/z13-power-validate"
SAMPLES="${STATE_DIR}/samples.log"
EVENTS="${STATE_DIR}/events.log"
PIDFILE="${STATE_DIR}/monitor.pid"
STARTFILE="${STATE_DIR}/start.epoch"
FANLOG="${STATE_DIR}/fan.log"
INTERVAL="${INTERVAL:-1}"
FAN_INTERVAL="${FAN_INTERVAL:-0.1}"
FAN_DELTA_THRESHOLD="${FAN_DELTA_THRESHOLD:-100}"

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

# The exact AC-line event count. asusd logs one line per notify, so this is the
# authoritative flap count and is not subject to sampling rate.
count_ac_events() { count_since_start "External power supply state changed"; }

# asusd rewrites the fan curve on every platform-profile change AND on every
# AC-line notify. With the debounce the first source is gone, so this count is
# (about) twice the AC-event count, one write each for CPU and GPU.
count_fan_curves() { count_since_start "write_profile_curve_to_platform"; }

count_ppd() { count_since_start "omarchy-powerprofiles-set"; }

# z13.battery logs each decision via logger -t z13-battery: "applying profile"
# for a settled real change, "left unchanged" for a flap that returned to where
# it started within the settle window.
count_z13_applied()   { count_since_start "z13-battery.*applying profile"; }
count_z13_absorbed()  { count_since_start "z13-battery.*left unchanged"; }

# Which shell service owns AC/battery profile switching right now.
battery_service() {
  local cfg="$HOME/.config/omarchy/shell.json"
  if [[ -f $cfg ]] && jq -e 'any(.plugins[]?; .id == "z13.battery")
       and any(.disabledPlugins[]?; . == "omarchy.battery")' "$cfg" >/dev/null 2>&1; then
    echo "z13.battery (debounced)"
  else
    echo "omarchy.battery (undebounced)"
  fi
}

# Read the profile from sysfs instead of spawning powerprofilesctl every tick.
# PPD maps its profiles onto platform_profile one-to-one; quiet is PPD's
# power-saver. asusd watches platform_profile, so this is the signal that
# actually drives a fan-curve write.
read_profile() {
  local p
  p=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null) || { echo n/a; return; }
  case "$p" in
    quiet)   echo power-saver ;;
    "")      echo n/a ;;
    *)       echo "$p" ;;
  esac
}

# UPower.onBattery is derived from the same AC line that flaps, and on this
# machine (no second supply) it is exactly "AC0 offline". Deriving it from sysfs
# avoids spawning busctl every tick, which was the sampling cost that let the
# CPU-starved loop undercount flaps. Falls back to a busctl read if AC0 is
# unreadable.
read_upower() {
  local a
  a=$(cat /sys/class/power_supply/AC0/online 2>/dev/null) || a=""
  case "$a" in
    1) echo false ;;
    0) echo true ;;
    *) busctl get-property org.freedesktop.UPower /org/freedesktop/UPower \
         org.freedesktop.UPower OnBattery 2>/dev/null | awk '{print $2}' || echo n/a ;;
  esac
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
  profile=$(read_profile)
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
    profile=$(read_profile)
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
      if [[ $status == "$prev_status" ]]; then
        printf '%s EVENT upower-flap %s->%s (bat_status=%s unchanged)\n' "$(date '+%H:%M:%S')" "$prev_upower" "$upower" "$status" >> "$EVENTS"
      fi
    fi

    prev_ac0="$ac0"; prev_status="$status"; prev_profile="$profile"; prev_gov="$gov"; prev_upower="$upower"
    sleep "$INTERVAL"
  done
}

# ------------------------------------------------------------------ fan probe
# Locate fan tach inputs by hwmon name so the numbers survive a hwmon renumber.
CPU_FAN=""; GPU_FAN=""; ACPI_FAN=""
find_fan_paths() {
  local h name
  for h in /sys/class/hwmon/hwmon*; do
    name=$(cat "$h/name" 2>/dev/null) || continue
    case "$name" in
      asus)     CPU_FAN="$h/fan1_input"; GPU_FAN="$h/fan2_input" ;;
      acpi_fan) ACPI_FAN="$h/fan1_input" ;;
    esac
  done
}

fan_sampler() {
  while :; do
    printf '%s %s %s %s %s %s\n' "$(date +%s.%N)" \
      "$(cat "$CPU_FAN" 2>/dev/null || echo na)" \
      "$(cat "$GPU_FAN" 2>/dev/null || echo na)" \
      "$(cat "$ACPI_FAN" 2>/dev/null || echo na)" \
      "$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo na)" \
      "$(read_profile)" >> "$FANLOG"
    sleep "$FAN_INTERVAL"
  done
}

# Report per-fan spread overall, and within +/-1.5 s of each AC0 transition.
# If asusd's writes actually moved the fans, the spread around the transitions
# would stand out from the overall spread.
fan_report() {
  if [[ ! -s $FANLOG ]]; then
    echo "(no fan samples)"
    return
  fi
  awk -v thresh="$FAN_DELTA_THRESHOLD" '
    function mn(a,b){ return (a==""||b<a)?b:a }
    function mx(a,b){ return (a==""||b>a)?b:a }
    { n++; t[n]=$1; cpu[n]=$2; gpu[n]=$3; acpi[n]=$4; ac0[n]=$5
      if(cpu[n]!="na"){ cmin=mn(cmin,cpu[n]); cmax=mx(cmax,cpu[n]); csum+=cpu[n]; cc++ }
      if(gpu[n]!="na"){ gmin=mn(gmin,gpu[n]); gmax=mx(gmax,gpu[n]); gsum+=gpu[n]; gc++ }
      if(acpi[n]!="na"){ amin=mn(amin,acpi[n]); amax=mx(amax,acpi[n]) }
    }
    END {
      printf "  overall: cpu %s..%s (mean %d)  gpu %s..%s (mean %d)  acpi %s..%s\n",
        cmin, cmax, (cc?csum/cc:0), gmin, gmax, (gc?gsum/gc:0), amin, amax
      e=0; prev=""
      for(i=1;i<=n;i++){ if(prev!="" && ac0[i]!=prev){ e++; et[e]=t[i] } prev=ac0[i] }
      if(e==0){ print "  no AC0 transitions in the fan window"; exit }
      worst=0
      for(k=1;k<=e;k++){
        wmnc=""; wmxc=""; wmng=""; wmxg=""
        for(i=1;i<=n;i++){
          d=t[i]-et[k]; if(d<-1.5||d>1.5) continue
          if(cpu[i]!="na"){ wmnc=mn(wmnc,cpu[i]); wmxc=mx(wmxc,cpu[i]) }
          if(gpu[i]!="na"){ wmng=mn(wmng,gpu[i]); wmxg=mx(wmxg,gpu[i]) }
        }
        dc=wmxc-wmnc; dg=wmxg-wmng
        printf "  AC0 change @%s: cpu %s..%s (d=%s)  gpu %s..%s (d=%s)\n",
          strftime("%H:%M:%S", et[k]), wmnc, wmxc, dc, wmng, wmxg, dg
        if(dc>worst) worst=dc
        if(dg>worst) worst=dg
      }
      printf "  worst within-window fan spread: %d RPM (threshold %d)\n", worst, thresh
      if(worst<=thresh)
        print "  -> Fan RPM did not move around the AC transitions: the fan-curve writes are benign."
      else
        print "  -> Fan RPM moved around AC transitions: the writes are not cosmetic."
    }
  ' "$FANLOG"
}

# --------------------------------------------------------------- orchestration
stop_monitors() {
  if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

print_report() {
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

  local ac_events ac0_sampled upower_sampled
  ac_events=$(count_ac_events)
  ac0_sampled=$(count_events 'EVENT ac0 ')
  upower_sampled=$(count_events 'EVENT upower ')

  echo "--- AC line (the cause; expected to flap) ---"
  echo "exact AC events (asusd journal):  $ac_events"
  echo "sampled AC0 toggles (1 s poll):   $ac0_sampled"
  echo "sampled onBattery changes:        $upower_sampled"
  grep 'EVENT ac0 ' "$EVENTS" 2>/dev/null | head -8 || true
  echo

  echo "--- profile changes (what the debounce protects) ---"
  local profile_changes gov_changes
  profile_changes=$(count_events 'EVENT profile')
  gov_changes=$(count_events 'EVENT governor')
  echo "count: $profile_changes"
  grep 'EVENT profile' "$EVENTS" 2>/dev/null || echo "(none)"
  echo "governor changes: $gov_changes"
  echo

  echo "--- asusd fan-curve writes (AC-driven; the debounce cannot stop these) ---"
  local fan_curves
  fan_curves=$(count_fan_curves)
  echo "count: $fan_curves  (expected ~2 per AC event: CPU + GPU)"
  echo

  echo "--- z13.battery decisions ---"
  echo "service:               $(battery_service)"
  echo "applied (real change): $(count_z13_applied)"
  echo "absorbed (flap):       $(count_z13_absorbed)"
  echo

  echo "=========================================================="
  echo " VERDICT"
  echo "=========================================================="
  # Pass/fail keys on PROFILE changes only. The debounce's whole job is to keep
  # the profile still while the AC line flaps; fan-curve writes are asusd's own
  # reaction to the AC line and scale with AC events, not with the profile.
  if (( profile_changes <= 2 )); then
    if (( ac_events == 0 && ac0_sampled == 0 )); then
      echo "AC line steady: no flap this window. It is intermittent, so absence here"
      echo "proves nothing."
    else
      echo "AC line flapped ($ac_events events) but the profile held ($profile_changes changes)."
      echo "-> Debounce is working: the flap no longer reaches the power profile."
      if (( ac_events > 0 && fan_curves >= 2 * ac_events )); then
        echo "-> asusd still rewrote the fan curve $fan_curves times: ~2 per AC event, so"
        echo "   it is reacting to the AC line directly, not to a profile change."
      fi
      if (( ac_events > 20 )); then
        echo "-> Flap persisted with the profile pinned, so profile switching is not"
        echo "   feeding it. Cause side: supply headroom (140 W vs stock 200 W)."
      fi
    fi
  else
    echo "Profile churned ($profile_changes changes) — the debounce is not holding."
    if [[ $(battery_service) == omarchy.battery* ]]; then
      echo "-> z13.battery is not active. Run phase 3 of install.sh, then"
      echo "   omarchy-restart-shell, and confirm: journalctl -b -t z13-battery"
    else
      echo "-> z13.battery is enabled but something else is switching profiles."
      echo "   Check DeckShift, Fn+F5, asusd change_platform_profile_on_*."
    fi
  fi
  echo
  echo "=========================================================="
  echo " HISTORY"
  echo "=========================================================="
  echo "Omarchy 3 (udev):        205 debounce invocations / 14 min while charging"
  echo "Quattro 2026-09-16:      0 flaps over 36->90% charge (missed: intermittent)"
  echo "Quattro 2026-10-10:      ~1 Hz storm under stress-ng/Lychee while charging,"
  echo "                         98 fan-curve writes in one boot (140 W supply)"
}

cmd_start() {
  if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  : > "$SAMPLES"; : > "$EVENTS"
  date +%s > "$STARTFILE"
  setsid "$0" _loop >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  echo "started (pid $(cat "$PIDFILE"))"
  echo "samples: $SAMPLES"
  echo "events:  $EVENTS"
  echo
  echo "Now: charge through the flap zone (or put load on while charging)."
  echo "Then run: $0 stop"
}

cmd_status() {
  echo "=== now ==="
  printf 'AC0 online:    %s\n' "$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)"
  printf 'BAT0 status:   %s\n' "$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)"
  printf 'BAT0 capacity: %s%%\n' "$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)"
  printf 'profile:       %s\n' "$(read_profile)"
  printf 'governor:      %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  printf 'UPower.onBattery: %s\n' "$(read_upower)"
  echo
  echo "=== since monitor start ==="
  printf 'exact AC events (journal):  %s\n' "$(count_ac_events)"
  printf 'sampled AC0 toggles:        %s\n' "$(count_events 'EVENT ac0 ')"
  printf 'sampled onBattery changes:  %s\n' "$(count_events 'EVENT upower ')"
  printf 'profile changes:            %s\n' "$(count_events 'EVENT profile')"
  printf 'governor changes:           %s\n' "$(count_events 'EVENT governor')"
  printf 'asusd fan-curve writes:     %s\n' "$(count_fan_curves)"
  printf 'z13.battery applied:        %s\n' "$(count_z13_applied)"
  printf 'z13.battery absorbed:       %s\n' "$(count_z13_absorbed)"
  printf 'battery service:            %s\n' "$(battery_service)"
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
  stop_monitors
  sleep 1
  print_report
}

# Shared precondition check for the load-driven modes.
require_ac() {
  if [[ $(cat /sys/class/power_supply/AC0/online 2>/dev/null) != 1 ]]; then
    echo "AC0 is offline: plug in before running this" >&2
    exit 1
  fi
}

cmd_loadtest() {
  local seconds="${1:-300}" threads="${2:-$(nproc)}"
  command -v stress-ng >/dev/null || { echo "stress-ng not installed (pacman -S stress-ng)" >&2; exit 1; }
  require_ac
  local status cap limit
  status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo n/a)
  cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)
  limit=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || echo n/a)
  echo "battery: ${cap}% ${status} (limit ${limit}%), service: $(battery_service)"
  [[ $status == Charging ]] || echo "warning: not charging; the flap is likelier while charge current flows" >&2

  : > "$SAMPLES"; : > "$EVENTS"
  date +%s > "$STARTFILE"
  monitor_loop >/dev/null 2>&1 &
  local mon=$!
  trap 'kill "$mon" 2>/dev/null; cmd_stop; exit 0' INT
  echo "load: stress-ng --cpu $threads for ${seconds}s (Ctrl-C to stop early)"
  stress-ng --cpu "$threads" --timeout "${seconds}s" --quiet || true
  # Let one settle window pass after load ends so a pending switch is counted.
  sleep 20
  kill "$mon" 2>/dev/null || true
  cmd_stop
}

cmd_fanprobe() {
  local seconds="${1:-120}" threads="${2:-$(nproc)}"
  command -v stress-ng >/dev/null || { echo "stress-ng not installed (pacman -S stress-ng)" >&2; exit 1; }
  require_ac
  find_fan_paths
  if [[ -z $CPU_FAN && -z $GPU_FAN && -z $ACPI_FAN ]]; then
    echo "no fan tach inputs found under /sys/class/hwmon" >&2
    exit 1
  fi
  echo "fans: cpu=${CPU_FAN:-n/a} gpu=${GPU_FAN:-n/a} acpi=${ACPI_FAN:-n/a}"

  : > "$SAMPLES"; : > "$EVENTS"; : > "$FANLOG"
  date +%s > "$STARTFILE"
  monitor_loop >/dev/null 2>&1 &
  local mon=$!
  fan_sampler >/dev/null 2>&1 &
  local fan=$!
  trap 'kill "$mon" "$fan" 2>/dev/null; cmd_stop; exit 0' INT

  echo "load: stress-ng --cpu $threads for ${seconds}s; sampling fans at ${FAN_INTERVAL}s"
  stress-ng --cpu "$threads" --timeout "${seconds}s" --quiet || true
  sleep 5
  kill "$mon" "$fan" 2>/dev/null || true
  sleep 1
  print_report
  echo
  echo "--- fan probe (does asusd's fan-curve write move the fans?) ---"
  fan_report
}

case "${1:-}" in
  start) cmd_start ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  _loop) monitor_loop ;;
  loadtest) shift; cmd_loadtest "$@" ;;
  fanprobe) shift; cmd_fanprobe "$@" ;;
  watch)
    : > "$SAMPLES"; : > "$EVENTS"
    date +%s > "$STARTFILE"
    echo "watching; Ctrl-C to stop"
    trap 'cmd_stop; exit 0' INT
    monitor_loop
    ;;
  *)
    echo "usage: $0 {start|status|stop|watch|loadtest [SECONDS] [THREADS]|fanprobe [SECONDS] [THREADS]}" >&2
    exit 1
    ;;
esac
