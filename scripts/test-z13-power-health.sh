#!/bin/bash
# Tests for scripts/z13-power-health.sh.
#
# Every input is a fixture: power-supply tree, platform_profile, per-source
# state files, a journal log file, a wrapper stub and a notification stub. No
# root, no real power events, no journal access.
#
# Run: scripts/test-z13-power-health.sh [path-to-health-script]

set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname -- "$HERE")
HEALTH="${1:-$REPO/scripts/z13-power-health.sh}"

[[ -r $HEALTH ]] || { echo "error: health script not found: $HEALTH" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z13-health-test.XXXXXX") || exit 2
FAILED=0

cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# Fresh sandbox. $1 = platform_profile, $2 = source (ac|battery).
setup() {
    local profile=${1:-performance} source=${2:-ac}
    rm -rf -- "$TMP/sys" "$TMP/run" "$TMP/config" "$TMP/statehome" \
              "$TMP/profiles" "$TMP/health" "$TMP/home"
    mkdir -p "$TMP/sys/BAT0" "$TMP/sys/AC0" "$TMP/run" \
             "$TMP/config/hypr" "$TMP/profiles" "$TMP/health" \
             "$TMP/home/.local/bin"
    printf 'Battery\n' > "$TMP/sys/BAT0/type"
    printf '89\n'      > "$TMP/sys/BAT0/capacity"
    printf 'Mains\n'   > "$TMP/sys/AC0/type"
    if [[ $source == ac ]]; then
        printf 'Not charging\n' > "$TMP/sys/BAT0/status"
        printf '1\n'            > "$TMP/sys/AC0/online"
    else
        printf 'Discharging\n' > "$TMP/sys/BAT0/status"
        printf '0\n'           > "$TMP/sys/AC0/online"
    fi
    printf '%s\n' "$profile" > "$TMP/platform_profile"
    printf 'performance\n' > "$TMP/profiles/ac"
    printf 'balanced\n'    > "$TMP/profiles/battery"
    printf 'hl.env("PATH", home .. "/.local/bin:" .. os.getenv("PATH"))\n' \
        > "$TMP/config/hypr/z13.lua"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/wrapper.calls"\n' "$TMP" \
        > "$TMP/home/.local/bin/omarchy-powerprofiles-set"
    chmod +x "$TMP/home/.local/bin/omarchy-powerprofiles-set"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notifications.log"\n' "$TMP" \
        > "$TMP/notify.sh"
    chmod +x "$TMP/notify.sh"
    : > "$TMP/journal.log"
    : > "$TMP/health.log"
    : > "$TMP/notifications.log"
    : > "$TMP/wrapper.calls"
}

run_health() {
    env HOME="$TMP/home" \
        XDG_RUNTIME_DIR="$TMP/run" \
        XDG_CONFIG_HOME="$TMP/config" \
        XDG_STATE_HOME="$TMP/statehome" \
        OMARCHY_POWERPROFILES_STATE_DIR="$TMP/profiles" \
        Z13_POWER_HEALTH_STATE_DIR="$TMP/health" \
        Z13_POWER_SUPPLY_ROOT="$TMP/sys" \
        Z13_PLATFORM_PROFILE="$TMP/platform_profile" \
        Z13_POWER_LOG="$TMP/journal.log" \
        Z13_HEALTH_LOG="$TMP/health.log" \
        Z13_NOTIFY_CMD="$TMP/notify.sh" \
        Z13_PROFILES_AVAILABLE="performance balanced power-saver" \
        Z13_SETTLE_SLEEP=0 \
        "$HEALTH" "$@"
}

# Extract a numeric or string field from the --json line.
json_field() { sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p"; }
json_text()  { json_field "$1" | tr -d '"'; }

# ── healthy: AC, profile matches the state file ─────────────────────────────
setup performance ac
out=$(run_health --json)
check "healthy AC: exit 0" test "$(run_health --json >/dev/null 2>&1; echo $?)" -eq 0
check "healthy AC: no warnings" test "$(printf '%s' "$out" | json_field warnings)" -eq 0
check "healthy AC: source ac" test "$(printf '%s' "$out" | json_text source)" = ac
check "healthy AC: profile performance" test "$(printf '%s' "$out" | json_text profile)" = performance

# ── healthy: battery, state file maps quiet -> power-saver ─────────────────
setup balanced battery
out=$(run_health --json)
check "healthy battery: no warnings" test "$(printf '%s' "$out" | json_field warnings)" -eq 0
check "healthy battery: source battery" test "$(printf '%s' "$out" | json_text source)" = battery

# ── stale sentinel: leak, notify once, then rate-limited ───────────────────
setup performance ac
mkdir "$TMP/run/z13-powerprofiles.processing"
printf 'pid=999\nparent=quickshell\n' > "$TMP/run/z13-powerprofiles.processing/owner"
touch -d '5 minutes ago' "$TMP/run/z13-powerprofiles.processing"
out=$(run_health --json)
check "sentinel: warning raised" test "$(printf '%s' "$out" | json_field warnings)" -ge 1
check "sentinel: age reported" sh -c "printf '%s' '$out' | grep -q 'sentinel\":\"age='"
run_health run >/dev/null
run_health run >/dev/null
check "sentinel: notification sent once (cooldown)" test "$(wc -l < "$TMP/notifications.log")" -eq 1

# ── stuck profile after a wrapper decision: alerts on the second run ───────
setup quiet ac
printf '1793895000.0 omarchy z13-powerprofiles[1]: settled on battery; applying power-saver\n' \
    > "$TMP/journal.log"
out1=$(run_health --json)
check "divergence: first run has no warning yet" test "$(printf '%s' "$out1" | json_field warnings)" -eq 0
out2=$(run_health --json)
check "divergence: second run warns" test "$(printf '%s' "$out2" | json_field warnings)" -ge 1
check "divergence: state is mismatch" sh -c "printf '%s' '$out2' | grep -q 'divergence\":\"mismatch(2)'"
run_health run >/dev/null
check "divergence: notification sent" grep -q 'divergence' "$TMP/notifications.log"

# ── manual override: same mismatch, no recent power activity ──────────────
setup quiet ac
out1=$(run_health --json)
out2=$(run_health --json)
check "override: no warning on first run" test "$(printf '%s' "$out1" | json_field warnings)" -eq 0
check "override: no warning on second run" test "$(printf '%s' "$out2" | json_field warnings)" -eq 0
check "override: state logged as override" sh -c "printf '%s' '$out2' | grep -q 'divergence\":\"override'"
check "override: no notification" test ! -s "$TMP/notifications.log"

# ── wrapper not in the compositor PATH ─────────────────────────────────────
setup performance ac
printf 'hl.env("PATH", os.getenv("PATH"))\n' > "$TMP/config/hypr/z13.lua"
out=$(run_health --json)
check "wrapper path: warning raised" test "$(printf '%s' "$out" | json_field warnings)" -ge 1
check "wrapper path: state not-on-path" test "$(printf '%s' "$out" | json_text wrapper)" = not-on-path

# ── wrapper never runs although AC events happen (shadowed) ────────────────
setup performance ac
printf '1793895000.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false\n' \
    > "$TMP/journal.log"
out=$(run_health --json)
check "shadowed: warning raised" test "$(printf '%s' "$out" | json_field warnings)" -ge 1
check "shadowed: state shadowed" test "$(printf '%s' "$out" | json_text wrapper)" = shadowed

# ── storm threshold ────────────────────────────────────────────────────────
setup performance ac
for _ in $(seq 1 130); do
    printf '1793895000.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false\n'
done > "$TMP/journal.log"
out=$(run_health --json)
check "storm: warning raised above 120 flaps/h" test "$(printf '%s' "$out" | json_field warnings)" -ge 1
check "storm: flap count recorded" test "$(printf '%s' "$out" | json_field flaps_1h)" -eq 130

# ── blip classification: down and back within 10 s ────────────────────────
setup performance ac
cat > "$TMP/journal.log" <<'EOF'
1793895000.0 omarchy z13-powerprofiles[1]: settled on battery; applying power-saver
1793895004.0 omarchy z13-powerprofiles[2]: settled on ac; applying performance
1793895100.0 omarchy z13-powerprofiles[3]: settled on battery; applying power-saver
1793895900.0 omarchy z13-powerprofiles[4]: settled on ac; applying performance
EOF
out=$(run_health --json)
check "blips: one paired blip counted" test "$(printf '%s' "$out" | json_field blips_1h)" -eq 1

# ── burst detection: >=3 AC-off edges close together ───────────────────────
setup performance ac
cat > "$TMP/journal.log" <<'EOF'
1793895000.0 omarchy z13-powerprofiles[1]: settled on ac; profile already performance
1793895010.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895015.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895020.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895025.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
EOF
out=$(run_health --json)
check "burst: four close edges count as one" test "$(printf '%s' "$out" | json_field bursts_1h)" -eq 1
check "burst without a blip: no warning" test "$(printf '%s' "$out" | json_field warnings)" -eq 0

# ── a burst that beat the guard is alerted under the burst key ────────────
setup performance ac
cat > "$TMP/journal.log" <<'EOF'
1793895000.0 omarchy z13-powerprofiles[1]: settled on ac; profile already performance
1793895010.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895015.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895020.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895025.0 omarchy asusd[1]: [DEBUG asusd] External power supply state changed: false
1793895030.0 omarchy z13-powerprofiles[2]: settled on battery; applying power-saver
1793895034.0 omarchy z13-powerprofiles[3]: settled on ac; applying performance
EOF
out=$(run_health --json)
check "burst + blip: warning raised" test "$(printf '%s' "$out" | json_field warnings)" -ge 1
check "burst + blip: one burst and one blip" sh -c "printf '%s' '$out' | grep -q '\"bursts_1h\":1' && printf '%s' '$out' | grep -q '\"blips_1h\":1'"
run_health run >/dev/null
check "burst + blip: burst key in summary" grep -q '\[burst' "$TMP/health.log"

# ── --fix: clears the sentinel and re-applies the expected profile ────────
setup quiet ac
mkdir "$TMP/run/z13-powerprofiles.processing"
printf 'pid=999\n' > "$TMP/run/z13-powerprofiles.processing/owner"
touch -d '5 minutes ago' "$TMP/run/z13-powerprofiles.processing"
run_health --fix >/dev/null 2>&1
check "fix: sentinel removed" test ! -e "$TMP/run/z13-powerprofiles.processing"
check "fix: wrapper asked for ac performance" grep -qx 'ac performance' "$TMP/wrapper.calls"

echo
if (( FAILED )); then
    echo "FAILED"
    exit 1
fi
echo "OK"
