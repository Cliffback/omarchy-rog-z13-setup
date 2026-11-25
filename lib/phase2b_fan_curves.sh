#!/bin/bash
# Phase 2b: leave custom fan curves to the firmware.
#
# On GZ302EA (BIOS 314) enabling an asusd custom fan curve was observed to pin
# fan 2 at ~6300 RPM; controlled re-tests at warm idle did not reproduce it. The
# EC's own per-profile tables are correct: with custom curves disabled, Quiet
# idles at 0 RPM and Balanced/Performance follow their firmware tables (0 RPM at
# cool idle, ramping with temperature and load). Balanced and Performance already
# ship with their curves disabled; Quiet is the only profile asusd enables by
# default. Keeping the curves off is the
# conservative default; scripts/z13-fan-curve-probe.sh checks the current state.
#
# See docs/z13-fan-curve-gz302ea.md.

# Overridable only so the dry-run path can be exercised against a fixture; the
# writes always go through asusctl and hit asusd's real config.
FAN_CURVE_CONFIG="${FAN_CURVE_CONFIG:-/etc/asusd/fan_curves.ron}"
FAN_PROFILES=(Quiet Balanced Performance)

# True when any firmware-profile curve is enabled. The `custom` profile is
# user-managed, so it is deliberately excluded: Phase 2b must leave it alone.
firmware_curves_enabled() {
    awk '
        /^[[:space:]]*[a-zA-Z_]+:[[:space:]]*\[/ {
            profile = $1
            sub(/:.*/, "", profile)
        }
        profile != "custom" && /enabled: true/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$FAN_CURVE_CONFIG"
}

phase2b_check() {
    # Nothing to manage before Phase 1 installs asusctl. Returning 0 here keeps
    # a fresh machine (or an aborted Phase 1) from prompting for this phase.
    has_command asusctl || return 0
    [[ -f "$FAN_CURVE_CONFIG" ]] || return 0
    ! firmware_curves_enabled
}

phase2b_run() {
    if ! has_command asusctl || [[ ! -f "$FAN_CURVE_CONFIG" ]]; then
        warn "asusctl or $FAN_CURVE_CONFIG not found — run Phase 1/2 first. Skipping."
        return
    fi

    # Use the CLI, never sed on the .ron: asusctl updates asusd's live config
    # and the persisted file together. The `custom` profile is left alone; it is
    # user-managed, not one of the firmware profile tables this phase owns.
    local profile
    for profile in "${FAN_PROFILES[@]}"; do
        info "Disabling custom fan curve for $profile..."
        run_sudo asusctl fan-curve --mod-profile "$profile" --enable-fan-curves false
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        return 0
    fi

    if firmware_curves_enabled; then
        warn "Some firmware-profile curves are still enabled — check $FAN_CURVE_CONFIG."
    else
        success "Custom fan curves disabled — the firmware's per-profile tables are in charge."
    fi
}
