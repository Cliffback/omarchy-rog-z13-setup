#!/bin/bash
# sched_ext A/B benchmark harness for the ROG Flow Z13.
#
# Measures what a CPU scheduler actually influences:
#   1. Throughput of a CPU-bound workload
#   2. Wake-up latency while CPU is saturated (the key metric for scx_lavd)
#   3. Process spawn latency under load
#
# Run once on EEVDF (baseline), then again with scx_lavd running, and compare.
# Usage: ./scx-bench.sh <label>
#   e.g. ./scx-bench.sh eevdf
#        ./scx-bench.sh lavd
#
# Requires: scx-latency (in ~/.local/bin), stress-ng, zstd
set -euo pipefail

LABEL="${1:-run}"
OUTDIR="${HOME}/scx-bench"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/${LABEL}-$(date +%Y%m%d-%H%M%S).txt"
DURATION="${DURATION:-20}"
LOAD_JOBS="${LOAD_JOBS:-32}"
LAT_ITERS="${LAT_ITERS:-3000}"

LATENCY_BIN="${HOME}/.local/bin/scx-latency"
LATENCY_SRC="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/scx-latency.c"
if [[ ! -x $LATENCY_BIN ]]; then
  if [[ -f $LATENCY_SRC ]] && command -v gcc >/dev/null; then
    echo "building scx-latency..." >&2
    gcc -O2 -o "$LATENCY_BIN" "$LATENCY_SRC" || {
      echo "error: failed to build scx-latency" >&2; exit 1; }
  else
    echo "error: $LATENCY_BIN not found and cannot build (need gcc + $LATENCY_SRC)" >&2
    exit 1
  fi
fi

exec > >(tee "$OUT")

echo "=========================================================="
echo " scx benchmark: $LABEL"
echo " date:     $(date -Is)"
echo " duration: ${DURATION}s per load test, jobs: ${LOAD_JOBS}, lat samples: ${LAT_ITERS}"
echo "=========================================================="

echo
echo "--- environment ---"
echo "sched_ext state : $(cat /sys/kernel/sched_ext/state 2>/dev/null || echo n/a)"
echo "active ops      : $(cat /sys/kernel/sched_ext/*/ops 2>/dev/null || echo none)"
echo "power profile   : $(powerprofilesctl get 2>/dev/null || echo n/a)"
echo "platform profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
echo "governor        : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "EPP             : $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"
echo "AC online       : $(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo n/a)"
echo "battery         : $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo n/a)%"
echo "kernel          : $(uname -r)"

START_PROFILE=$(powerprofilesctl get 2>/dev/null || echo n/a)
START_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Continuous power-state drift monitor.
#
# A start/end comparison misses a transient flip that returns to its original
# value, which is exactly the failure mode the Z13's spurious power events
# produce. Sample every 0.5s in the background and record every change.
# ---------------------------------------------------------------------------
DRIFT_FILE="$TMP/drift.log"
: > "$DRIFT_FILE"
monitor_power_state() {
  local prev_p prev_g p g
  prev_p="$START_PROFILE"
  prev_g="$START_GOV"
  while :; do
    p=$(powerprofilesctl get 2>/dev/null || echo n/a)
    g=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
    if [[ $p != "$prev_p" || $g != "$prev_g" ]]; then
      printf '%s profile=%s->%s governor=%s->%s\n' \
        "$(date +%H:%M:%S)" "$prev_p" "$p" "$prev_g" "$g" >> "$DRIFT_FILE"
      prev_p="$p"; prev_g="$g"
    fi
    sleep 0.5
  done
}
monitor_power_state &
MONITOR_PID=$!
DRIFT_MONITOR_ACTIVE=1
stop_monitor() {
  [[ -n ${DRIFT_MONITOR_ACTIVE:-} ]] || return 0
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
  DRIFT_MONITOR_ACTIVE=""
}
trap 'stop_monitor; rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------
# 0. Idle wake latency (no load) - reference point
# ---------------------------------------------------------------
echo
echo "--- [0/3] idle wake latency ---"
IDLE_LAT=$("$LATENCY_BIN" "$LAT_ITERS" 1000)
echo "$IDLE_LAT"
IDLE_MEAN=$(echo "$IDLE_LAT" | grep -oP '(?<=mean=)[0-9.]+')
IDLE_P50=$(echo "$IDLE_LAT" | grep -oP '(?<=p50=)[0-9.]+')
IDLE_P95=$(echo "$IDLE_LAT" | grep -oP '(?<=p95=)[0-9.]+')
IDLE_P99=$(echo "$IDLE_LAT" | grep -oP '(?<=p99=)[0-9.]+')
IDLE_MAX=$(echo "$IDLE_LAT" | grep -oP '(?<=max=)[0-9.]+')

# ---------------------------------------------------------------
# 1. Throughput: parallel CPU-bound work
# ---------------------------------------------------------------
echo
echo "--- [1/3] throughput: parallel zstd (CPU-bound) ---"
# 256M, level 3, 32 jobs: several seconds of sustained saturation.
head -c 256M /dev/urandom > "$TMP/data.bin"
start=$(date +%s.%N)
ZSTD_PIDS=()
for i in $(seq 1 "$LOAD_JOBS"); do
  zstd -q -3 -f "$TMP/data.bin" -o "$TMP/out-$i.zst" &
  ZSTD_PIDS+=($!)
done
# Wait only for the zstd jobs: a bare `wait` would also block on the
# long-running drift monitor and hang the benchmark.
for pid in "${ZSTD_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
end=$(date +%s.%N)
THROUGHPUT_TIME=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", b-a}')
echo "wall time for ${LOAD_JOBS}x zstd -3 on 256M: ${THROUGHPUT_TIME}s"

# ---------------------------------------------------------------
# 2. Wake latency while CPU is saturated (the key metric)
# ---------------------------------------------------------------
echo
echo "--- [2/3] wake latency under saturation ---"
stress-ng --cpu "$LOAD_JOBS" --timeout "${DURATION}s" --quiet &
STRESS_PID=$!
sleep 3
LOAD_LAT=$("$LATENCY_BIN" "$LAT_ITERS" 1000)
echo "$LOAD_LAT"
LOAD_MEAN=$(echo "$LOAD_LAT" | grep -oP '(?<=mean=)[0-9.]+')
LOAD_P50=$(echo "$LOAD_LAT" | grep -oP '(?<=p50=)[0-9.]+')
LOAD_P95=$(echo "$LOAD_LAT" | grep -oP '(?<=p95=)[0-9.]+')
LOAD_P99=$(echo "$LOAD_LAT" | grep -oP '(?<=p99=)[0-9.]+')
LOAD_MAX=$(echo "$LOAD_LAT" | grep -oP '(?<=max=)[0-9.]+')
wait "$STRESS_PID" 2>/dev/null || true

# ---------------------------------------------------------------
# 3. Process spawn latency under load
# ---------------------------------------------------------------
echo
echo "--- [3/3] process spawn latency under load ---"
stress-ng --cpu "$LOAD_JOBS" --timeout "${DURATION}s" --quiet &
STRESS_PID=$!
sleep 3

start=$(date +%s.%N)
for _ in $(seq 1 500); do
  /bin/true
done
end=$(date +%s.%N)
SPAWN_TIME=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')
wait "$STRESS_PID" 2>/dev/null || true
echo "500x /bin/true under load: ${SPAWN_TIME}s"

echo
echo "=========================================================="
echo " SUMMARY ($LABEL)"
echo "=========================================================="
printf "throughput wall time : %s s\n" "$THROUGHPUT_TIME"
printf "spawn 500x true      : %s s\n" "$SPAWN_TIME"
echo "(see latency percentiles above)"

# Warn if the power profile drifted during the run: it invalidates comparisons.
stop_monitor
END_PROFILE=$(powerprofilesctl get 2>/dev/null || echo n/a)
END_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
DRIFT_COUNT=$(wc -l < "$DRIFT_FILE" 2>/dev/null || echo 0)
if [[ $END_PROFILE != "$START_PROFILE" || $END_GOV != "$START_GOV" || $DRIFT_COUNT -gt 0 ]]; then
  echo
  echo "!! WARNING: power state changed during this run !!"
  echo "   start: profile=$START_PROFILE governor=$START_GOV"
  echo "   end:   profile=$END_PROFILE governor=$END_GOV"
  if (( DRIFT_COUNT > 0 )); then
    echo "   $DRIFT_COUNT transition(s) observed:"
    sed 's/^/     /' "$DRIFT_FILE"
  fi
  echo "   Results may be unreliable. Re-run with a pinned profile."
  PROFILE_STABLE=no
else
  PROFILE_STABLE=yes
fi

echo
echo "saved: $OUT"

# Machine-readable results for scx-ab-test.sh
cat > "${OUT}.summary" <<EOF
label=$LABEL
sched_ext_state=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo n/a)
active_ops=$(cat /sys/kernel/sched_ext/*/ops 2>/dev/null || echo none)
power_profile=$(powerprofilesctl get 2>/dev/null || echo n/a)
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
profile_stable=$PROFILE_STABLE
profile_drift_count=$DRIFT_COUNT
idle_mean=$IDLE_MEAN
idle_p50=$IDLE_P50
idle_p95=$IDLE_P95
idle_p99=$IDLE_P99
idle_max=$IDLE_MAX
load_mean=$LOAD_MEAN
load_p50=$LOAD_P50
load_p95=$LOAD_P95
load_p99=$LOAD_P99
load_max=$LOAD_MAX
throughput_s=$THROUGHPUT_TIME
spawn_s=$SPAWN_TIME
EOF
echo "summary: ${OUT}.summary"
