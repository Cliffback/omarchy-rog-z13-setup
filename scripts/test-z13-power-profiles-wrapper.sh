#!/bin/bash
# Tests for templates/omarchy-powerprofiles-set-debounced.
#
# The wrapper is exercised against a fixture power-supply tree, a stub original
# script, a fixture platform_profile and an extra-first log, so nothing here
# touches the live profile or the system journal.
#
# What is asserted:
#   * a 1 s or 2 s AC flap never applies the battery profile (the 2026-11-05
#     charge-boundary behaviour);
#   * a sustained unplug still applies the battery profile after the ~3 s
#     settle window;
#   * a 1 Hz storm never settles and changes nothing;
#   * explicit profile picks bypass settling;
#   * the sentinel is always removed, a held sentinel is logged, a stale one is
#     reclaimed, and a usage error still cleans up.
#
# Run: scripts/test-z13-power-profiles-wrapper.sh [path-to-wrapper]

set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname -- "$HERE")
WRAPPER="${1:-$REPO/templates/omarchy-powerprofiles-set-debounced}"

[[ -r $WRAPPER ]] || { echo "error: wrapper not found: $WRAPPER" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z13-wrapper-test.XXXXXX") || exit 2
BAT="$TMP/sys/BAT0"
CALLS="$TMP/calls.log"
EXTRA_LOG="$TMP/wrapper.log"
SENTINEL="$TMP/run/z13-powerprofiles.processing"
FAILED=0
DRIVER_PID=""

cleanup() {
    [[ -n $DRIVER_PID ]] && kill "$DRIVER_PID" 2>/dev/null
    DRIVER_PID=""
    rm -rf -- "$TMP"
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
check() {
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}
not_grep() { ! grep -q -- "$1" "$2"; }

# Fresh fixture for one scenario. $1 is the platform_profile to report.
setup() {
    [[ -n $DRIVER_PID ]] && kill "$DRIVER_PID" 2>/dev/null
    DRIVER_PID=""
    rm -rf -- "$TMP/sys" "$TMP/run" "$TMP/state" "$TMP/home"
    mkdir -p "$BAT" "$TMP/sys/AC0" "$TMP/run" "$TMP/state" "$TMP/home"
    printf 'Battery\n'      > "$BAT/type"
    printf 'Not charging\n' > "$BAT/status"
    printf '89\n'           > "$BAT/capacity"
    printf 'Mains\n'        > "$TMP/sys/AC0/type"
    printf '1\n'            > "$TMP/sys/AC0/online"
    printf '%s\n' "${1:-performance}" > "$TMP/platform_profile"
    : > "$CALLS"
    : > "$EXTRA_LOG"
}

run_wrapper() {
    env HOME="$TMP/home" \
        XDG_RUNTIME_DIR="$TMP/run" \
        OMARCHY_POWERPROFILES_STATE_DIR="$TMP/state" \
        Z13_POWER_SUPPLY_ROOT="$TMP/sys" \
        Z13_PLATFORM_PROFILE="$TMP/platform_profile" \
        Z13_ORIG_SCRIPT="$TMP/orig.sh" \
        Z13_PROFILES_AVAILABLE="performance balanced power-saver" \
        Z13_POWER_LOG="$EXTRA_LOG" \
        Z13_SETTLE_INTERVAL=1 \
        "$WRAPPER" "$@"
}

cat > "$TMP/orig.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS_LOG"
EOF
chmod +x "$TMP/orig.sh"
export CALLS_LOG="$CALLS"

# Drive BAT0.status from a list of "status:seconds" pairs, in the background.
drive() {
    (
        local spec status dur
        for spec in "$@"; do
            status=${spec%:*}
            dur=${spec##*:}
            printf '%s\n' "$status" > "$BAT/status"
            sleep "$dur"
        done
    ) &
    DRIVER_PID=$!
}

# ── 1 s flap: the charge-boundary case ───────────────────────────────────────
setup balanced
drive "Discharging:1.5" "Not charging:20"
run_wrapper ac
check "1 s flap: never settled on battery" not_grep 'settled on battery' "$EXTRA_LOG"
check "1 s flap: no battery profile applied" not_grep battery "$CALLS"
check "1 s flap: sentinel removed" test ! -e "$SENTINEL"

# ── 2 s flap: the slowest flap seen on 2026-11-05 ───────────────────────────
setup balanced
drive "Discharging:2.5" "Not charging:20"
run_wrapper ac
check "2 s flap: never settled on battery" not_grep 'settled on battery' "$EXTRA_LOG"
check "2 s flap: no battery profile applied" not_grep battery "$CALLS"

# ── genuine unplug: must still apply after ~3 s ─────────────────────────────
setup performance
drive "Discharging:30"
run_wrapper ac
check "real unplug: settled on battery" grep -q 'settled on battery' "$EXTRA_LOG"
check "real unplug: applied battery" grep -qx 'battery' "$CALLS"
check "real unplug: sentinel removed" test ! -e "$SENTINEL"

# ── storm: nothing settles, so nothing may change ───────────────────────────
setup performance
(
    for i in $(seq 1 10); do
        if (( i % 2 )); then printf 'Discharging\n'; else printf 'Not charging\n'; fi > "$BAT/status"
        sleep 1.2
    done
) &
DRIVER_PID=$!
run_wrapper ac
check "storm: no profile settled" not_grep 'settled on' "$EXTRA_LOG"
check "storm: no profile applied" test ! -s "$CALLS"
check "storm: logged as unsettled" grep -q 'did not settle' "$EXTRA_LOG"
check "storm: sentinel removed" test ! -e "$SENTINEL"

# ── explicit pick bypasses settling ─────────────────────────────────────────
setup balanced
drive "Discharging:2.0" "Not charging:20"
run_wrapper ac balanced
check "explicit pick: applied even mid-flap" grep -qx 'ac balanced' "$CALLS"
check "explicit pick: sentinel removed" test ! -e "$SENTINEL"

# ── a held sentinel is logged, not silently dropped ─────────────────────────
setup balanced
mkdir "$SENTINEL"
printf 'pid=4242\nparent=quickshell\n' > "$SENTINEL/owner"
drive "Not charging:20"
run_wrapper ac
check "held sentinel: original script not called" test ! -s "$CALLS"
check "held sentinel: logged with owner" grep -q 'skipped: sentinel held.*pid=4242.*parent=quickshell' "$EXTRA_LOG"

# ── a stale sentinel is reclaimed ───────────────────────────────────────────
setup balanced
mkdir "$SENTINEL"
printf 'pid=1\nparent=systemd\n' > "$SENTINEL/owner"
touch -d '2 minutes ago' "$SENTINEL"
drive "Not charging:20"
run_wrapper ac
check "stale sentinel: reclaimed and applied" grep -qx 'ac' "$CALLS"
check "stale sentinel: logged reclaim" grep -q 'reclaiming stale sentinel' "$EXTRA_LOG"
check "stale sentinel: removed afterwards" test ! -e "$SENTINEL"

# ── usage error still cleans up ─────────────────────────────────────────────
setup balanced
run_wrapper a b c
check "usage error: passed through" grep -qx 'a b c' "$CALLS"
check "usage error: sentinel removed" test ! -e "$SENTINEL"

echo
if (( FAILED )); then
    echo "FAILED"
    exit 1
fi
echo "OK"
