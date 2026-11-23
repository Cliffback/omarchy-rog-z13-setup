#!/bin/bash
# Phase 20: AMD Display Freeze Fix (DMCUB)
# The display microcontroller (DMCUB) on Strix Halo can crash while it moves
# the panel in or out of a power-saving state. The session keeps running, but
# the panel stays dark/frozen. Disabling PSR and Panel Replay via
# amdgpu.dcdebugmask is the common mitigation. See
# docs/amdgpu-dmcub-display-freeze.md.
#
# Override the mask with Z13_DCDEBUGMASK, e.g. Z13_DCDEBUGMASK=0xC10 to also
# disable IPS (idle power states) if 0x410 alone does not stop the freezes.
#
# The parameter lives in its own drop-in. An earlier version edited
# /etc/default/limine because a plain `KERNEL_CMDLINE[default]=` there was
# discarding every drop-in; ensure_limine_dropins_effective now fixes that
# instead, and this phase moves any mask left in /etc/default/limine into the
# drop-in so there is one source.

AMDGPU_DROPIN_NAME="amdgpu-display.conf"
AMDGPU_DCDEBUGMASK="${Z13_DCDEBUGMASK:-0x410}"

phase20_check() {
    grep -qw "amdgpu.dcdebugmask=${AMDGPU_DCDEBUGMASK}" /proc/cmdline 2>/dev/null \
        && [[ -f "$LIMINE_DROPIN_DIR/$AMDGPU_DROPIN_NAME" ]] \
        && ! grep -q 'amdgpu\.dcdebugmask=' "$LIMINE_DEFAULT_CONF" 2>/dev/null
}

phase20_run() {
    info "Installing the amdgpu display freeze workaround (dcdebugmask=${AMDGPU_DCDEBUGMASK})..."
    info "0x10 disables PSR, 0x400 disables Panel Replay, 0x800 disables IPS."

    ensure_limine_dropins_effective || return 1

    # Move a mask written by the old version of this phase (or by hand) out of
    # /etc/default/limine. Only the parameter is removed, never the line: it
    # may sit inside the main line with root=, cryptdevice= and resume=.
    if grep -q 'amdgpu\.dcdebugmask=' "$LIMINE_DEFAULT_CONF" 2>/dev/null; then
        info "Moving amdgpu.dcdebugmask out of $LIMINE_DEFAULT_CONF into the drop-in..."
        run_sudo cp "$LIMINE_DEFAULT_CONF" "${LIMINE_DEFAULT_CONF}.bak.rog-z13.$(date +%s)"
        run_sudo sed -i -E 's/ ?amdgpu\.dcdebugmask=[^ "]*//g' "$LIMINE_DEFAULT_CONF"
    fi

    write_limine_dropin "$AMDGPU_DROPIN_NAME" \
        "AMD display freeze fix (DMCUB, Strix Halo): 0x10 PSR off, 0x400 Panel Replay off, 0x800 IPS off" \
        "amdgpu.dcdebugmask=${AMDGPU_DCDEBUGMASK}"
    success "Wrote $LIMINE_DROPIN_DIR/$AMDGPU_DROPIN_NAME"

    rebuild_limine_and_verify "amdgpu.dcdebugmask=${AMDGPU_DCDEBUGMASK}" || return 1

    NEEDS_REBOOT=1
    warn "A reboot is required. The parameter is read-only at runtime."
    info "After reboot: cat /sys/module/amdgpu/parameters/dcdebugmask  (0x410 = 1040, 0xC10 = 3088)"
}
