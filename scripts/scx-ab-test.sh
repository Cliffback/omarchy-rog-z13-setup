#!/bin/bash
# Automated A/B test: EEVDF vs a sched_ext scheduler on the ROG Flow Z13.
#
# Runs the benchmark on the stock scheduler, then with the scx scheduler loaded,
# then prints a side-by-side comparison. Requires sudo once to load the scheduler.
#
# Usage: ./scx-ab-test.sh [scheduler] [flags...]
#   e.g. ./scx-ab-test.sh                          # scx_lavd --autopower
#        ./scx-ab-test.sh scx_lavd --performance
#        ./scx-ab-test.sh scx_bpfland
set -euo pipefail

SCHED="${1:-scx_lavd}"
shift || true
SCHED_FLAGS=("$@")
[[ ${#SCHED_FLAGS[@]} -gt 0 ]] || SCHED_FLAGS=(--autopower)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="${SCRIPT_DIR}/scx-bench.sh"
OUTDIR="${HOME}/scx-bench"

[[ -x $BENCH ]] || { echo "error: $BENCH not found" >&2; exit 1; }
command -v "$SCHED" >/dev/null || { echo "error: $SCHED not installed" >&2; exit 1; }

# --- preflight ---------------------------------------------------------
if [[ -n $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null) ]]; then
  echo "error: a sched_ext scheduler is already running ($(cat /sys/kernel/sched_ext/*/ops))" >&2
  echo "stop it first (Ctrl-C it, or: sudo systemctl stop scx)" >&2
  exit 1
fi

echo "==> A/B test: EEVDF vs ${SCHED} ${SCHED_FLAGS[*]}"
echo "==> AC: $(cat /sys/class/power_supply/AC0/online)  profile: $(powerprofilesctl get)"
echo

# The Z13's spurious UCSI power_supply events fire the debounced profile
# switcher, which would change the CPU governor mid-benchmark. Pin the
# profile for the duration and restore it afterwards.
#
# Note: a `powerprofilesctl launch` hold does NOT protect against this,
# because an explicit `powerprofilesctl set` (which the debounce script
# issues) overrides the hold. The real protection is the v5 debounce fix,
# whose idempotency guard now keeps the profile steady. scx-bench.sh
# independently verifies this with its drift monitor.
ORIG_PROFILE=$(powerprofilesctl get 2>/dev/null || echo "")
SCHED_PID=""

restore_profile() {
  [[ -n $ORIG_PROFILE ]] && powerprofilesctl set "$ORIG_PROFILE" 2>/dev/null || true
}
cleanup() {
  [[ -n $SCHED_PID ]] && sudo kill "$SCHED_PID" 2>/dev/null || true
  restore_profile
}
trap cleanup EXIT

if [[ -n $ORIG_PROFILE ]]; then
  echo "==> Pinning power profile to 'performance' for the test (was: $ORIG_PROFILE)"
  powerprofilesctl set performance
fi
sleep 1
echo "    profile: $(powerprofilesctl get)  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo

# Acquire sudo up front so the test isn't interrupted mid-run.
sudo -v

# --- 1. baseline ------------------------------------------------------
echo "==> [1/2] Baseline on EEVDF"
"$BENCH" "ab-eevdf" >/dev/null
EEVDF_SUM=$(ls -t "$OUTDIR"/ab-eevdf-*.summary | head -1)
echo "    done: $EEVDF_SUM"

# --- 2. scx scheduler -------------------------------------------------
echo
echo "==> [2/2] Loading ${SCHED} ${SCHED_FLAGS[*]}"
sudo "$SCHED" "${SCHED_FLAGS[@]}" > "$OUTDIR/${SCHED}-sched.log" 2>&1 &
SCHED_PID=$!

for _ in $(seq 1 20); do
  [[ -n $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null) ]] && break
  sleep 0.5
done
ACTIVE=$(cat /sys/kernel/sched_ext/*/ops 2>/dev/null || echo "")
if [[ -z $ACTIVE ]]; then
  echo "error: ${SCHED} failed to load. Log:" >&2
  cat "$OUTDIR/${SCHED}-sched.log" >&2
  exit 1
fi
echo "    active scheduler: ${ACTIVE}"

"$BENCH" "ab-${SCHED}" >/dev/null
SCX_SUM=$(ls -t "$OUTDIR"/ab-${SCHED}-*.summary | head -1)
echo "    done: $SCX_SUM"

# --- stop the scheduler ----------------------------------------------
sudo kill "$SCHED_PID" 2>/dev/null || true
wait "$SCHED_PID" 2>/dev/null || true
SCHED_PID=""
sleep 1
echo
echo "==> Scheduler unloaded, back on EEVDF (state=$(cat /sys/kernel/sched_ext/state))"

# --- comparison -------------------------------------------------------
get() { grep -oP "(?<=^${2}=).*" "$1"; }

echo
echo "=========================================================="
echo " COMPARISON: EEVDF vs ${SCHED} ${SCHED_FLAGS[*]}"
echo "=========================================================="
printf "%-26s %12s %12s\n" "metric" "EEVDF" "$SCHED"
printf "%-26s %12s %12s\n" "--------------------------" "------------" "------------"

row() {
  local label="$1" key="$2"
  printf "%-26s %12s %12s\n" "$label" "$(get "$EEVDF_SUM" "$key")" "$(get "$SCX_SUM" "$key")"
}

row "idle wake mean (us)"  idle_mean
row "idle wake p99 (us)"   idle_p99
row "load wake mean (us)"  load_mean
row "load wake p50 (us)"   load_p50
row "load wake p95 (us)"   load_p95
row "load wake p99 (us)"   load_p99
row "load wake max (us)"   load_max
row "throughput (s)"       throughput_s
row "spawn 500x true (s)"  spawn_s
row "profile stable"       profile_stable
row "profile drift count"  profile_drift_count

echo
echo "Lower is better for all metrics (profile stable must be 'yes')."
echo

EEVDF_STABLE=$(get "$EEVDF_SUM" profile_stable)
SCX_STABLE=$(get "$SCX_SUM" profile_stable)
if [[ $EEVDF_STABLE != yes || $SCX_STABLE != yes ]]; then
  echo "!! RESULTS INVALID: power profile drifted during a run."
  echo "   EEVDF stable=$EEVDF_STABLE   ${SCHED} stable=$SCX_STABLE"
  echo "   Inspect the drift lines in the raw .txt files, fix the cause,"
  echo "   then re-run. Do not draw conclusions from this comparison."
  echo
  echo "EEVDF summary: $EEVDF_SUM"
  echo "SCX summary:   $SCX_SUM"
  exit 2
fi

echo "EEVDF summary: $EEVDF_SUM"
echo "SCX summary:   $SCX_SUM"
echo
echo "Scheduler log: $OUTDIR/${SCHED}-sched.log"
