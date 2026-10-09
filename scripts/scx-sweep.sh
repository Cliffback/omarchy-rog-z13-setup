#!/bin/bash
# Compare wake latency under CPU saturation across sched_ext configurations.
#
# Wake latency under load is the metric scx_lavd targets, and the one that
# discriminated EEVDF (53us) from scx_lavd --performance (~860us) in the full
# A/B runs. This sweep is faster than repeated A/B runs when you only need
# that metric, and lets you try several tunings back to back.
#
# Usage: ./scx-sweep.sh [config ...]
#   config format: "label:scheduler flags"
#   With no arguments the default configs below are used.
#
# Requires sudo to load schedulers. Run from a terminal (or with cached sudo);
# the script pins the power profile for the duration and restores it after.
set -euo pipefail

LOAD_JOBS="${LOAD_JOBS:-32}"
LAT_ITERS="${LAT_ITERS:-2000}"
WARMUP="${WARMUP:-4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LATENCY_BIN="${HOME}/.local/bin/scx-latency"

if [[ $# -gt 0 ]]; then
  CONFIGS=("$@")
else
  CONFIGS=(
    "lavd-default:scx_lavd --performance"
    "lavd-preempt3:scx_lavd --performance --preempt-shift 3"
    "lavd-slice1k:scx_lavd --performance --slice-max-us 1000"
    "bpfland:scx_bpfland"
  )
fi

if [[ ! -x $LATENCY_BIN ]]; then
  if [[ -f $SCRIPT_DIR/scx-latency.c ]] && command -v gcc >/dev/null; then
    echo "building scx-latency..." >&2
    gcc -O2 -o "$LATENCY_BIN" "$SCRIPT_DIR/scx-latency.c"
  else
    echo "error: $LATENCY_BIN missing and cannot build (need gcc + scx-latency.c)" >&2
    exit 1
  fi
fi

if [[ -n $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null) ]]; then
  echo "error: scheduler already running: $(cat /sys/kernel/sched_ext/*/ops)" >&2
  exit 1
fi

ORIG_PROFILE=$(powerprofilesctl get 2>/dev/null || echo "")
STRESS_PID=""
SCHED_PID=""

cleanup() {
  [[ -n $STRESS_PID ]] && kill "$STRESS_PID" 2>/dev/null || true
  [[ -n $SCHED_PID ]] && sudo kill "$SCHED_PID" 2>/dev/null || true
  [[ -n $ORIG_PROFILE ]] && powerprofilesctl set "$ORIG_PROFILE" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n $ORIG_PROFILE ]]; then
  powerprofilesctl set performance
fi
sleep 1
echo "profile: $(powerprofilesctl get)  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo

# Measure wake latency and spawn latency under a single saturating load.
measure() {
  stress-ng --cpu "$LOAD_JOBS" --quiet &
  STRESS_PID=$!
  sleep "$WARMUP"

  "$LATENCY_BIN" "$LAT_ITERS" 1000 | tail -1

  local s e spawn
  s=$(date +%s.%N)
  for _ in $(seq 1 500); do /bin/true; done
  e=$(date +%s.%N)
  spawn=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}')
  echo "spawn 500x true: ${spawn}s"

  kill "$STRESS_PID" 2>/dev/null || true
  wait "$STRESS_PID" 2>/dev/null || true
  STRESS_PID=""
}

echo "=========================================================="
echo " baseline: EEVDF"
echo "=========================================================="
BASE_OUT=$(measure)
echo "$BASE_OUT"
echo

RESULTS=("EEVDF|$(echo "$BASE_OUT" | grep -oP '(?<=mean=)[0-9.]+')|$(echo "$BASE_OUT" | grep -oP '(?<=p99=)[0-9.]+')|$(echo "$BASE_OUT" | grep -oP '(?<=true: )[0-9.]+')")

for cfg in "${CONFIGS[@]}"; do
  label="${cfg%%:*}"
  flags="${cfg#*:}"
  read -ra ARGS <<< "$flags"
  sched="${ARGS[0]}"

  echo "=========================================================="
  echo " ${label}: ${flags}"
  echo "=========================================================="

  sudo "${ARGS[@]}" > "/tmp/scx-sweep-${label}.log" 2>&1 &
  SCHED_PID=$!

  for _ in $(seq 1 20); do
    [[ -n $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null) ]] && break
    sleep 0.5
  done

  if [[ -z $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null) ]]; then
    echo "FAILED to load ${sched}. Log:"
    cat "/tmp/scx-sweep-${label}.log"
    sudo kill "$SCHED_PID" 2>/dev/null || true
    wait "$SCHED_PID" 2>/dev/null || true
    SCHED_PID=""
    echo
    continue
  fi

  OUT=$(measure)
  echo "$OUT"

  sudo kill "$SCHED_PID" 2>/dev/null || true
  wait "$SCHED_PID" 2>/dev/null || true
  SCHED_PID=""
  sleep 1

  RESULTS+=("${label}|$(echo "$OUT" | grep -oP '(?<=mean=)[0-9.]+')|$(echo "$OUT" | grep -oP '(?<=p99=)[0-9.]+')|$(echo "$OUT" | grep -oP '(?<=true: )[0-9.]+')")
  echo
done

echo "=========================================================="
echo " SUMMARY (wake latency under load, microseconds)"
echo "=========================================================="
printf "%-20s %8s %8s %10s\n" "config" "mean" "p99" "spawn(s)"
printf "%-20s %8s %8s %10s\n" "--------------------" "--------" "--------" "----------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r l m p s <<< "$r"
  printf "%-20s %8s %8s %10s\n" "$l" "$m" "$p" "$s"
done
echo
echo "profile after sweep: $(powerprofilesctl get)"
