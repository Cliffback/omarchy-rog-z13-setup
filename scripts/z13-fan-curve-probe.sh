#!/bin/bash
# Measure whether an asusd custom fan curve pins fan 2 on the ROG Flow Z13.
#
# On GZ302EA (BIOS 314) enabling a custom curve for the active platform profile
# was observed to pin the second fan at ~6300-6400 RPM even at ~36 C and 12-18 W.
# The pin is not reliably reproducible, so this probe checks the current state.
# The EC's own per-profile tables are correct; the probe toggles the active
# profile's curves off -> on -> off, samples fan2_input by hwmon name (never by
# index), and restores the original state on exit.
#
# Enabling the curve can make the fan loud for roughly 20 seconds. Run at idle.
#
# Usage:
#   ./scripts/z13-fan-curve-probe.sh
#   ./scripts/z13-fan-curve-probe.sh --seconds 20 --settle 5
#   ./scripts/z13-fan-curve-probe.sh --dry-run
#   ./scripts/z13-fan-curve-probe.sh --help
#
# See docs/z13-fan-curve-gz302ea.md.
set -euo pipefail

WINDOW_SECONDS=15
SETTLE_SECONDS=5
SAMPLE_INTERVAL=1
PIN_THRESHOLD=1000
TEMP_SPREAD_LIMIT=5
DRY_RUN=0

# ── Colors / logging ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

run_sudo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: sudo $*"
        return 0
    fi
    sudo "$@"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Measure whether an asusd custom fan curve pins fan 2 on the ROG Flow Z13.
The probe toggles the ACTIVE profile's curves off -> on -> off, samples
fan2_input (hwmon name=asus) at idle, and restores the original state on exit.

Options:
  --seconds N     sample window per state (default: $WINDOW_SECONDS)
  --settle N      seconds to wait after toggling (default: $SETTLE_SECONDS)
  --threshold N   RPM delta that counts as pinned (default: $PIN_THRESHOLD)
  --dry-run       print what would run; change nothing
  -h, --help      show this help
EOF
}

# ── Arguments ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --seconds)   WINDOW_SECONDS="${2:?--seconds needs a value}"; shift 2 ;;
        --settle)    SETTLE_SECONDS="${2:?--settle needs a value}"; shift 2 ;;
        --threshold) PIN_THRESHOLD="${2:?--threshold needs a value}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)
            error "unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

for value in "$WINDOW_SECONDS" "$SETTLE_SECONDS" "$PIN_THRESHOLD"; do
    if [[ ! $value =~ ^[0-9]+$ ]]; then
        error "options must be non-negative integers (got: $value)"
        exit 2
    fi
done
if (( WINDOW_SECONDS == 0 )); then
    error "--seconds must be greater than zero"
    exit 2
fi

if [[ $EUID -eq 0 ]]; then
    error "Run this as your normal user; sudo is used internally."
    exit 1
fi

if ! command -v asusctl >/dev/null 2>&1; then
    error "asusctl not found — install asusctl / enable asusd first."
    exit 1
fi

# ── Discovery (by hwmon name, never by index) ────────────────────────────
find_hwmon() {
    local name="$1" file="$2" h
    for h in /sys/class/hwmon/hwmon*; do
        if [[ "$(cat "$h/name" 2>/dev/null)" == "$name" ]]; then
            printf '%s\n' "$h/$file"
            return 0
        fi
    done
    return 1
}

FAN2=$(find_hwmon asus fan2_input) || { error "fan2_input not found under hwmon name=asus"; exit 1; }
FAN1=$(find_hwmon asus fan1_input) || FAN1=""
CPU_TEMP=$(find_hwmon k10temp temp1_input) || CPU_TEMP=""
GPU_TEMP=$(find_hwmon amdgpu temp1_input) || GPU_TEMP=""

read_uint() {
    local file="$1" value
    [[ -n $file && -r $file ]] || return 1
    value=$(cat "$file" 2>/dev/null) || return 1
    [[ $value =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

read_temp_c() {
    local file="$1" value
    [[ -n $file && -r $file ]] || return 1
    value=$(cat "$file" 2>/dev/null) || return 1
    [[ $value =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( value / 1000 ))"
}

active_profile() {
    local profile
    profile=$(asusctl profile get 2>/dev/null \
        | sed -n 's/^Active profile: //p' | head -n1) || profile=""
    if [[ -z $profile ]]; then
        profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null) || profile=""
        case "$profile" in
            quiet)       profile="Quiet" ;;
            balanced)    profile="Balanced" ;;
            performance) profile="Performance" ;;
            *)           return 1 ;;
        esac
    fi
    printf '%s\n' "$profile"
}

# `--get-enabled` reports the ACTIVE profile (it cannot inspect a named one),
# which is exactly what this probe toggles.
curve_state() {
    local fan="$1" out state
    out=$(asusctl fan-curve --get-enabled 2>/dev/null) || return 1
    state=$(printf '%s\n' "$out" \
        | sed -n "s/^${fan}: enabled: \(true\|false\).*/\1/p" | head -n1)
    [[ -n $state ]] || return 1
    printf '%s\n' "$state"
}

set_all_curves() {
    local enable="$1"
    run_sudo asusctl fan-curve --mod-profile "$ACTIVE_PROFILE" --enable-fan-curves "$enable"
}

set_one_curve() {
    local fan="$1" enable="$2"
    run_sudo asusctl fan-curve --mod-profile "$ACTIVE_PROFILE" --enable-fan-curve "$enable" --fan "$fan"
}

restore_curves() {
    [[ ${CURVES_TOUCHED:-0} -eq 1 ]] || return 0
    info "Restoring original fan-curve state (CPU=${ORIG_CPU:-?} GPU=${ORIG_GPU:-?})..."
    if [[ -n ${ORIG_CPU:-} ]]; then
        set_one_curve cpu "$ORIG_CPU" || return 1
    fi
    if [[ -n ${ORIG_GPU:-} ]]; then
        set_one_curve gpu "$ORIG_GPU" || return 1
    fi
    CURVES_TOUCHED=0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ ${CURVES_TOUCHED:-0} -eq 1 ]]; then
        if ! restore_curves; then
            warn "Could not restore the original fan-curve state."
            if [[ -n ${ORIG_CPU:-} ]]; then
                warn "Restore manually: sudo asusctl fan-curve --mod-profile $ACTIVE_PROFILE --enable-fan-curve $ORIG_CPU --fan cpu"
            fi
            if [[ -n ${ORIG_GPU:-} ]]; then
                warn "Restore manually: sudo asusctl fan-curve --mod-profile $ACTIVE_PROFILE --enable-fan-curve $ORIG_GPU --fan gpu"
            fi
        fi
    fi
    exit "$rc"
}

# ── Sampling ─────────────────────────────────────────────────────────────
WIN_GPU_MEAN=0
WIN_TEMP_MIN=""
WIN_TEMP_MAX=""

sample_window() {
    local label="$1" secs="$2"
    local start=$SECONDS n=0
    local gpu_sum=0 cpu_sum=0 cpu_count=0
    local gpu_min="" gpu_max="" cpu_min="" cpu_max=""
    local tmin="" tmax=""
    local gpu cpu temp

    while (( SECONDS - start < secs )); do
        gpu=$(read_uint "$FAN2") || { error "could not read $FAN2"; return 1; }
        cpu=$(read_uint "$FAN1" 2>/dev/null) || cpu=""
        temp=$(read_temp_c "$CPU_TEMP" 2>/dev/null) || temp=""

        if [[ -z $gpu_min ]] || (( gpu < gpu_min )); then gpu_min=$gpu; fi
        if [[ -z $gpu_max ]] || (( gpu > gpu_max )); then gpu_max=$gpu; fi
        gpu_sum=$(( gpu_sum + gpu ))

        if [[ -n $cpu ]]; then
            if [[ -z $cpu_min ]] || (( cpu < cpu_min )); then cpu_min=$cpu; fi
            if [[ -z $cpu_max ]] || (( cpu > cpu_max )); then cpu_max=$cpu; fi
            cpu_sum=$(( cpu_sum + cpu ))
            cpu_count=$(( cpu_count + 1 ))
        fi

        if [[ -n $temp ]]; then
            if [[ -z $tmin ]] || (( temp < tmin )); then tmin=$temp; fi
            if [[ -z $tmax ]] || (( temp > tmax )); then tmax=$temp; fi
        fi

        n=$(( n + 1 ))
        sleep "$SAMPLE_INTERVAL"
    done

    if (( n == 0 )); then
        error "no samples collected for $label"
        return 1
    fi

    WIN_GPU_MEAN=$(( gpu_sum / n ))
    WIN_TEMP_MIN=${tmin:-n/a}
    WIN_TEMP_MAX=${tmax:-n/a}

    local cpu_mean="n/a" cpu_min_out="n/a" cpu_max_out="n/a"
    if (( cpu_count > 0 )); then
        cpu_mean=$(( cpu_sum / cpu_count ))
        cpu_min_out=$cpu_min
        cpu_max_out=$cpu_max
    fi

    printf '  %-7s gpu %4s..%4s RPM (mean %4d)   cpu %4s..%4s (mean %4s)   temp %s..%s C\n' \
        "$label" "${gpu_min:-n/a}" "${gpu_max:-n/a}" "$WIN_GPU_MEAN" \
        "$cpu_min_out" "$cpu_max_out" "$cpu_mean" \
        "$WIN_TEMP_MIN" "$WIN_TEMP_MAX"
}

ALL_TEMP_MIN=""
ALL_TEMP_MAX=""
track_temp() {
    if [[ $WIN_TEMP_MIN == "n/a" || $WIN_TEMP_MAX == "n/a" ]]; then
        return 0
    fi
    if [[ -z $ALL_TEMP_MIN ]] || (( WIN_TEMP_MIN < ALL_TEMP_MIN )); then
        ALL_TEMP_MIN=$WIN_TEMP_MIN
    fi
    if [[ -z $ALL_TEMP_MAX ]] || (( WIN_TEMP_MAX > ALL_TEMP_MAX )); then
        ALL_TEMP_MAX=$WIN_TEMP_MAX
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────
ACTIVE_PROFILE=$(active_profile) || { error "could not determine the active platform profile"; exit 1; }
ORIG_CPU=$(curve_state CPU) || { error "could not read the CPU curve state (is asusd running?)"; exit 1; }
ORIG_GPU=$(curve_state GPU) || { error "could not read the GPU curve state (is asusd running?)"; exit 1; }

info "Active profile: $ACTIVE_PROFILE"
info "Fan 2 (GPU):    $FAN2"
info "Fan 1 (CPU):    ${FAN1:-n/a}"
info "CPU temp:       ${CPU_TEMP:-n/a}"
info "GPU temp:       ${GPU_TEMP:-n/a}"
info "Original curve: CPU=$ORIG_CPU GPU=$ORIG_GPU"

if [[ $ORIG_CPU == "true" || $ORIG_GPU == "true" ]]; then
    warn "A custom curve is already enabled; the probe will restore that state (and its fan pin) on exit."
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    info "[DRY-RUN] planned sequence for $ACTIVE_PROFILE:"
    info "[DRY-RUN]   sudo asusctl fan-curve --mod-profile $ACTIVE_PROFILE --enable-fan-curves false"
    info "[DRY-RUN]   settle ${SETTLE_SECONDS}s, sample $WINDOW_SECONDS s (off-1)"
    info "[DRY-RUN]   sudo asusctl fan-curve --mod-profile $ACTIVE_PROFILE --enable-fan-curves true"
    info "[DRY-RUN]   settle ${SETTLE_SECONDS}s, sample $WINDOW_SECONDS s (on)"
    info "[DRY-RUN]   sudo asusctl fan-curve --mod-profile $ACTIVE_PROFILE --enable-fan-curves false"
    info "[DRY-RUN]   settle ${SETTLE_SECONDS}s, sample $WINDOW_SECONDS s (off-2)"
    info "[DRY-RUN]   restore CPU=$ORIG_CPU GPU=$ORIG_GPU on exit"
    exit 0
fi

sudo -v || { error "sudo is required to toggle fan curves"; exit 1; }

CURVES_TOUCHED=1
trap cleanup EXIT INT TERM

echo
info "Custom curves OFF; settling ${SETTLE_SECONDS}s..."
set_all_curves false
sleep "$SETTLE_SECONDS"
sample_window "off-1" "$WINDOW_SECONDS"
OFF1_GPU=$WIN_GPU_MEAN
track_temp

echo
info "Custom curves ON; settling ${SETTLE_SECONDS}s..."
set_all_curves true
sleep "$SETTLE_SECONDS"
sample_window "on" "$WINDOW_SECONDS"
ON_GPU=$WIN_GPU_MEAN
track_temp

echo
info "Custom curves OFF again; settling ${SETTLE_SECONDS}s..."
set_all_curves false
sleep "$SETTLE_SECONDS"
sample_window "off-2" "$WINDOW_SECONDS"
OFF2_GPU=$WIN_GPU_MEAN
track_temp

OFF_GPU_MEAN=$(( (OFF1_GPU + OFF2_GPU) / 2 ))
DELTA=$(( ON_GPU - OFF_GPU_MEAN ))
TEMP_SPREAD=""
TEMP_DESC="unavailable"
if [[ -n $ALL_TEMP_MIN && -n $ALL_TEMP_MAX ]]; then
    TEMP_SPREAD=$(( ALL_TEMP_MAX - ALL_TEMP_MIN ))
    TEMP_DESC="${ALL_TEMP_MIN}..${ALL_TEMP_MAX} C (spread ${TEMP_SPREAD} C)"
fi

echo
echo "=========================================================="
echo " FAN-CURVE PROBE"
echo "=========================================================="
printf 'profile:          %s\n' "$ACTIVE_PROFILE"
printf 'fan 2 off mean:   %d RPM (off-1 %d, off-2 %d)\n' "$OFF_GPU_MEAN" "$OFF1_GPU" "$OFF2_GPU"
printf 'fan 2 on mean:    %d RPM\n' "$ON_GPU"
printf 'delta (on - off): %+d RPM (threshold %d)\n' "$DELTA" "$PIN_THRESHOLD"
printf 'temperature:      %s\n' "$TEMP_DESC"
echo

if [[ -z $TEMP_SPREAD ]]; then
    warn "Temperature unavailable; the flat-temperature check did not run."
elif (( TEMP_SPREAD > TEMP_SPREAD_LIMIT )); then
    warn "Temperature moved ${TEMP_SPREAD} C across the run; the RPM comparison is confounded."
fi

if (( DELTA >= PIN_THRESHOLD )); then
    if [[ -n $TEMP_SPREAD ]] && (( TEMP_SPREAD <= TEMP_SPREAD_LIMIT )); then
        success "Curve enabled -> fan 2 rose ${DELTA} RPM at a flat temperature."
    else
        success "Curve enabled -> fan 2 rose ${DELTA} RPM."
    fi
    echo "-> The custom curve writes pin fan 2. Keep custom curves disabled (Phase 2b)."
elif (( DELTA <= -PIN_THRESHOLD )); then
    warn "Curve enabled -> fan 2 fell ${DELTA} RPM (unexpected)."
    echo "-> Re-run the probe and check the curve state before drawing a conclusion."
else
    echo "-> No pinning detected at idle (delta ${DELTA} RPM)."
    echo "   Re-run near 36 C idle, or check that the curve actually enabled."
fi
