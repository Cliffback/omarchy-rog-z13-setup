#!/bin/bash
# z13-power-health: periodic, report-only health check for the Z13 power-profile
# path. Installed by Phase 3 and driven by z13-power-health.timer
# (systemd --user, every 5 minutes).
#
# Why: every failure mode on this path is silent by nature. A dropped call looks
# like "nothing happened", a stale sentinel looks like a hung wrapper, a
# corrupt per-source state file looks like a switch that did nothing, and a
# shadowed PATH means the wrapper never runs at all. Each one presents as "the
# laptop randomly went quiet". This check turns them into one journal line per
# run and a desktop notification when something is actually wrong.
#
# Modes:
#   run       all checks; log one summary line; notify on anomaly (default)
#   status    human-readable snapshot, no notification, no logging
#   --json    machine-readable result (used by the tests)
#   --fix     manual repair: clear a stale sentinel, then re-apply the
#             state-file profile for the current source. Never used by the
#             timer: auto-healing would hide the regression this exists to
#             expose.
#
# Exit: 0 healthy, 1 anomaly, 2 usage/misconfiguration.
#
# Read state from sysfs and busctl, never from powerprofilesctl: that is a
# PyGObject script, and Omarchy avoids spawning it because a CPython 3.14
# shutdown race (python/cpython#124619) can kill it with SIGSEGV.
#
# Test seams (also used by scripts/test-z13-power-health.sh): Z13_POWER_SUPPLY_ROOT,
# Z13_PLATFORM_PROFILE, OMARCHY_POWERPROFILES_STATE_DIR, Z13_POWER_HEALTH_STATE_DIR,
# Z13_POWER_LOG (a file read instead of journalctl), Z13_HEALTH_LOG, Z13_NOTIFY_CMD,
# Z13_PROFILES_AVAILABLE, Z13_SETTLE_SLEEP.

set -u

POWER_SUPPLY_ROOT="${Z13_POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
PLATFORM_PROFILE_PATH="${Z13_PLATFORM_PROFILE:-/sys/firmware/acpi/platform_profile}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SENTINEL="${RUNTIME_DIR}/z13-powerprofiles.processing"
WRAPPER="${HOME:-/root}/.local/bin/omarchy-powerprofiles-set"
HYPR_LUA="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/hypr/z13.lua"
PROFILES_DIR="${OMARCHY_POWERPROFILES_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/omarchy/powerprofiles}"
HEALTH_DIR="${Z13_POWER_HEALTH_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/z13-power-health}"
POWER_LOG_SOURCE="${Z13_POWER_LOG:-}"
HEALTH_LOG="${Z13_HEALTH_LOG:-}"
NOTIFY_CMD="${Z13_NOTIFY_CMD:-omarchy-notification-send}"
SETTLE_SLEEP="${Z13_SETTLE_SLEEP:-1}"
NOW=$(date +%s)

SENTINEL_MAX_AGE=60        # a run takes ~1 s; a minute means leak or wedge
DIVERGENCE_MIN_RUNS=2      # 2 x 5 min before a mismatch is called
RECENT_ACTIVITY=600        # 10 min: mismatch is switch-related...
STORM_FLAPS_PER_HOUR=120   # ...and a storm is the only flap-rate alert
NOTIFY_COOLDOWN=3600

usage() {
    cat >&2 <<'EOF'
Usage: z13-power-health [run|status|--json|--fix]

  run      all checks, log one summary line, notify on anomaly (default)
  status   human-readable snapshot, no notification
  --json   machine-readable result
  --fix    clear a stale sentinel and re-apply the state-file profile
EOF
}

log() {
    if [[ -n $HEALTH_LOG ]]; then
        printf '%s\n' "$*" >> "$HEALTH_LOG" 2>/dev/null || true
        return 0
    fi
    logger -t z13-power-health "$*" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------

find_system_battery() {
    local ps scope
    for ps in "$POWER_SUPPLY_ROOT"/*; do
        [[ -r $ps/type && -r $ps/status ]] || continue
        [[ $(cat "$ps/type") == Battery ]] || continue
        scope=$(cat "$ps/scope" 2>/dev/null || echo "")
        [[ $scope == Device ]] && continue
        printf '%s\n' "$ps"
        return 0
    done
    return 1
}

read_ac_source() {
    local ps type
    for ps in "$POWER_SUPPLY_ROOT"/*; do
        [[ -r $ps/online && -r $ps/type ]] || continue
        type=$(cat "$ps/type")
        [[ $type == Mains || $type == USB ]] || continue
        [[ $(cat "$ps/online") == 1 ]] && { printf 'ac\n'; return; }
    done
    printf 'battery\n'
}

# Two agreeing reads, like the wrapper, so a flap is not mistaken for a source.
read_source() {
    local bat s1 s2
    if bat=$(find_system_battery); then
        s1=$(cat "$bat/status" 2>/dev/null || echo "")
        sleep "$SETTLE_SLEEP"
        s2=$(cat "$bat/status" 2>/dev/null || echo "")
        [[ $s1 == "$s2" ]] || { printf 'unknown\n'; return; }
        case "$s1" in
            Discharging)                  printf 'battery\n' ;;
            Charging|"Not charging"|Full) printf 'ac\n' ;;
            *)                            printf 'unknown\n' ;;
        esac
        return
    fi
    read_ac_source
}

# PPD maps its profiles one-to-one onto platform_profile.
read_platform_profile() {
    local p
    p=$(cat "$PLATFORM_PROFILE_PATH" 2>/dev/null) || return 1
    [[ -n $p ]] || return 1
    case "$p" in
        quiet) printf 'power-saver\n' ;;
        *)     printf '%s\n' "$p" ;;
    esac
}

profile_available() {
    if [[ -n ${Z13_PROFILES_AVAILABLE:-} ]]; then
        [[ " ${Z13_PROFILES_AVAILABLE} " == *" $1 "* ]]
        return
    fi
    busctl get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles \
        net.hadess.PowerProfiles Profiles 2>/dev/null | grep -q "\"$1\""
}

# The profile the wrapper would apply for this source. Mirrors its fallback:
# state file first, then ac -> performance, otherwise balanced.
expected_for() {
    local f="$PROFILES_DIR/$1" p=""
    [[ -r $f ]] && p=$(<"$f")
    if [[ -z $p ]]; then
        if [[ $1 == ac ]] && profile_available performance; then
            p=performance
        else
            p=balanced
        fi
    fi
    printf '%s\n' "$p"
}

# ---------------------------------------------------------------------------
# Journal counting
# ---------------------------------------------------------------------------

# $1 = seconds back, $2 = optional syslog tag. Tag filtering matters: a 7-day
# unscoped query scans the whole journal every 5 minutes, while `-t` uses the
# identifier index and keeps the check cheap.
journal_since() {
    if [[ -n $POWER_LOG_SOURCE ]]; then
        # Fixture mode: honour the tag by matching the "tag[pid]" field so the
        # tests exercise the same filtering as the real journal.
        if [[ -n ${2:-} ]]; then
            grep -F -- "$2[" "$POWER_LOG_SOURCE" 2>/dev/null
        else
            cat "$POWER_LOG_SOURCE" 2>/dev/null
        fi
        return
    fi
    local -a args=(--since "@$((NOW - $1))" --no-pager)
    [[ -n ${2:-} ]] && args+=(-t "$2")
    journalctl "${args[@]}" 2>/dev/null
}

# Same window with epoch-prefixed lines. Burst clustering needs real
# timestamps, and `-o short-unix` is locale-independent.
journal_since_unix() {
    local secs=$1 tag=${2:-}
    if [[ -n $POWER_LOG_SOURCE ]]; then
        if [[ -n $tag ]]; then
            grep -F -- "${tag}[" "$POWER_LOG_SOURCE" 2>/dev/null
        else
            cat "$POWER_LOG_SOURCE" 2>/dev/null
        fi
        return
    fi
    local -a args=(--since "@$((NOW - secs))" -o short-unix --no-pager)
    [[ -n $tag ]] && args+=(-t "$tag")
    journalctl "${args[@]}" 2>/dev/null
}

count_fixed() { journal_since "$1" "${3:-}" | grep -cF -- "$2" || true; }
count_re()    { journal_since "$1" "${3:-}" | grep -c  -- "$2" || true; }

# Profile changes that were undone within 10 s: the visible "brief quiet" blip.
# Only automatic switches (settled lines) count; explicit picks are deliberate.
count_blips() {
    if [[ -n $POWER_LOG_SOURCE ]]; then
        journal_since "$1"
    else
        journalctl -t z13-powerprofiles --since "@$((NOW - $1))" -o short-unix --no-pager 2>/dev/null
    fi | awk '
        { if (!match($0, /^[0-9]+(\.[0-9]+)?/)) next
          ts = substr($0, 1, RLENGTH) + 0 }
        /settled on .*; applying / {
          line = $0
          sub(/.*; applying /, "", line)
          sub(/[^a-z-].*/, "", line)
          if (prev != "" && line != prev && ts - prev_ts <= 10) {
              blips++
              prev = ""
          } else {
              prev = line
              prev_ts = ts
          }
        }
        END { print blips + 0 }
    '
}

# Bursts: groups of at least three AC-off edges with no more than 30 s between
# consecutive edges. One flap is two edges (off/on); three or more off-edges
# close together is the regime that can outlast the debounce. A sustained storm
# is one group, not one per 30 s window.
count_bursts() {
    journal_since_unix "$1" asusd \
        | grep -F 'External power supply state changed: false' \
        | awk '
            match($0, /^[0-9]+(\.[0-9]+)?/) { ts[n++] = substr($0, 1, RLENGTH) + 0 }
            END {
                i = 0
                while (i < n) {
                    j = i
                    while (j + 1 < n && ts[j+1] - ts[j] <= 30) j++
                    if (j - i + 1 >= 3) bursts++
                    i = j + 1
                }
                print bursts + 0
            }
        '
}

# ---------------------------------------------------------------------------
# State and notifications
# ---------------------------------------------------------------------------

WARNINGS=()  # "key: detail"
add_warning() { WARNINGS+=("$1: $2"); }

notify_once() {
    local key=$1 headline=$2 body=$3 stamp="$HEALTH_DIR/notified-$1" last=0
    mkdir -p "$HEALTH_DIR" 2>/dev/null || true
    [[ -r $stamp ]] && last=$(<"$stamp")
    (( NOW - last < NOTIFY_COOLDOWN )) && return 0
    printf '%s\n' "$NOW" > "$stamp" 2>/dev/null || true
    if command -v "$NOTIFY_CMD" >/dev/null 2>&1; then
        "$NOTIFY_CMD" -u normal "Z13 power: $headline" "$body" >/dev/null 2>&1 || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send -u normal "Z13 power: $headline" "$body" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# 1. The wrapper must be installed and must be what the compositor resolves.
check_wrapper() {
    wrapper_state="ok"
    if [[ ! -x $WRAPPER ]]; then
        wrapper_state="missing"
        add_warning wrapper "not executable: $WRAPPER"
        return
    fi
    if [[ ! -f $HYPR_LUA ]] || ! grep -q 'local/bin' "$HYPR_LUA"; then
        wrapper_state="not-on-path"
        add_warning wrapper "z13.lua does not prepend ~/.local/bin; the packaged script wins"
        return
    fi
    # Derived check: asusd logs every AC edge, so a week of edges with no
    # wrapper line means the wrapper is not resolving at all.
    local ac7 w7
    ac7=$(count_fixed 604800 'External power supply state changed' asusd)
    w7=$(count_re 604800 '.' z13-powerprofiles)
    if (( ac7 > 0 && w7 == 0 )); then
        wrapper_state="shadowed"
        add_warning wrapper "$ac7 AC events in 7 days but no wrapper decisions: not on PATH"
    fi
}

# 2. A sentinel older than a run is a leak, not contention.
check_sentinel() {
    sentinel_state="absent"
    sentinel_age=0
    [[ -e $SENTINEL ]] || return
    sentinel_age=$(( NOW - $(stat -c %Y "$SENTINEL" 2>/dev/null || echo "$NOW") ))
    sentinel_state="age=${sentinel_age}s"
    if (( sentinel_age > SENTINEL_MAX_AGE )); then
        local owner="unknown"
        [[ -r $SENTINEL/owner ]] && owner=$(tr '\n' ' ' < "$SENTINEL/owner" 2>/dev/null)
        add_warning sentinel "age=${sentinel_age}s owner=${owner:-unknown}"
    fi
}

# 3. The profile must match what the state file says for the current source.
#    A mismatch counts only when it began next to a power event or a wrapper
#    decision; otherwise it is a deliberate manual override.
check_divergence() {
    divergence_state="ok"
    local counter="$HEALTH_DIR/divergence"

    if [[ $source == unknown ]]; then
        divergence_state="source-unsettled"
        return
    fi
    if [[ -z $profile || $profile == unknown ]]; then
        divergence_state="profile-unreadable"
        return
    fi

    if [[ $profile == "$expected" ]]; then
        rm -f -- "$counter" 2>/dev/null
        return
    fi

    local count=0 since=$NOW suspicious=no stored_since stored_suspicious
    if [[ -r $counter ]]; then
        count=$(sed -n 's/^count=//p' "$counter" 2>/dev/null)
        stored_since=$(sed -n 's/^since=//p' "$counter" 2>/dev/null)
        stored_suspicious=$(sed -n 's/^suspicious=//p' "$counter" 2>/dev/null)
        [[ -n $stored_since ]] && since=$stored_since
        [[ -n $stored_suspicious ]] && suspicious=$stored_suspicious
    else
        if (( $(count_re "$RECENT_ACTIVITY" '.' z13-powerprofiles) + \
               $(count_fixed "$RECENT_ACTIVITY" 'External power supply state changed' asusd) > 0 )); then
            suspicious=yes
        fi
    fi
    count=$(( count + 1 ))
    mkdir -p "$HEALTH_DIR" 2>/dev/null || true
    {
        printf 'count=%s\n' "$count"
        printf 'since=%s\n' "$since"
        printf 'suspicious=%s\n' "$suspicious"
    } > "$counter" 2>/dev/null || true

    if [[ $suspicious == yes ]]; then
        divergence_state="mismatch(${count})"
        if (( count >= DIVERGENCE_MIN_RUNS )); then
            add_warning divergence "profile=$profile expected=$expected source=$source since=$(( NOW - since ))s"
        fi
    else
        divergence_state="override(profile=$profile expected=$expected)"
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

mkdir -p "$HEALTH_DIR" 2>/dev/null || true

source=$(read_source)
profile=$(read_platform_profile 2>/dev/null || echo unknown)
expected=""
[[ $source != unknown ]] && expected=$(expected_for "$source")

check_wrapper
check_sentinel
check_divergence

flaps_1h=$(count_fixed 3600 'External power supply state changed: false' asusd)
changes_1h=$(count_re 3600 'applying' z13-powerprofiles)
skipped_1h=$(count_re 3600 'skipped:' z13-powerprofiles)
blips_1h=$(count_blips 3600)
bursts_1h=$(count_bursts 3600)

# A storm is the only flap-rate alert: the usual 60-70/h boundary chatter is
# known EC behaviour and is recorded, not notified.
if (( flaps_1h > STORM_FLAPS_PER_HOUR )); then
    add_warning flaps "flaps_1h=$flaps_1h (storm; check supply headroom: 200 W stock, 140 W SlimQ)"
fi

# A burst matters only when it beat the guard and produced a visible blip; a
# burst the guard absorbed stays silent.
if (( bursts_1h > 0 && blips_1h > 0 )); then
    add_warning burst "bursts_1h=$bursts_1h blips_1h=$blips_1h: debounce beaten"
fi

warning_count=${#WARNINGS[@]}
keys=""
if (( warning_count > 0 )); then
    for w in "${WARNINGS[@]}"; do
        keys+="${w%%:*} "
    done
    keys=${keys% }
    status_text="WARN"
else
    status_text="ok"
fi

summary="health $status_text profile=${profile:-unknown} expected=${expected:-n/a} source=$source sentinel=$sentinel_state div=$divergence_state wrapper=$wrapper_state flaps_1h=$flaps_1h changes_1h=$changes_1h blips_1h=$blips_1h bursts_1h=$bursts_1h skipped_1h=$skipped_1h warnings=$warning_count"
(( warning_count > 0 )) && summary+=" [${keys}]"

mode="${1:-run}"
case "$mode" in
    run)
        log "$summary"
        for w in "${WARNINGS[@]:-}"; do
            [[ -n $w ]] || continue
            notify_once "${w%%:*}" "${w%%:*}" "${w#*: }"
        done
        ;;
    status)
        cat <<EOF
=== now ===
source:            $source
platform_profile:  ${profile:-unknown}
expected:          ${expected:-n/a}
wrapper:           $wrapper_state
sentinel:          $sentinel_state
divergence:        $divergence_state

=== last hour ===
AC flaps:          $flaps_1h
profile changes:   $changes_1h
brief blips:       $blips_1h
AC bursts:         $bursts_1h
wrapper skips:     $skipped_1h

=== warnings ===
EOF
        if (( warning_count == 0 )); then
            echo "(none)"
        else
            printf '%s\n' "${WARNINGS[@]}"
        fi
        ;;
    --json)
        printf '{"status":"%s","source":"%s","profile":"%s","expected":"%s","wrapper":"%s","sentinel":"%s","divergence":"%s","flaps_1h":%s,"changes_1h":%s,"blips_1h":%s,"bursts_1h":%s,"skipped_1h":%s,"warnings":%s}\n' \
            "$status_text" "$source" "${profile:-unknown}" "${expected:-}" \
            "$wrapper_state" "$sentinel_state" "$divergence_state" \
            "$flaps_1h" "$changes_1h" "$blips_1h" "$bursts_1h" "$skipped_1h" "$warning_count"
        ;;
    --fix)
        log "fix requested: $summary"
        if [[ -e $SENTINEL ]]; then
            log "fix: removing sentinel ($sentinel_state)"
            rm -rf -- "$SENTINEL"
        fi
        if [[ $source != unknown ]]; then
            log "fix: applying ${expected:-balanced} for $source"
            "$WRAPPER" "$source" "${expected:-balanced}" >/dev/null 2>&1 || true
        fi
        exec "$0" status
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

(( warning_count > 0 )) && exit 1
exit 0
