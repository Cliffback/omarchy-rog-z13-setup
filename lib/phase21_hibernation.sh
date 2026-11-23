#!/bin/bash
# Phase 21: Hibernation (optional)
# Sets up hibernation with Omarchy's own tooling (btrfs /swap subvolume,
# RAM-sized swapfile, mkinitcpio resume hook, resume= drop-in), then checks
# the parts that have gone wrong on this machine before a reboot is allowed:
#   - a plain KERNEL_CMDLINE[default]= in /etc/default/limine silently dropped
#     the resume= drop-in, so the kernel never knew where the image was;
#   - resume_offset must match the swapfile's current physical offset
#     (`btrfs inspect-internal map-swapfile -r`); a recreated swapfile moves it;
#   - the pending command line (limine-entry-tool --get-cmdline) must carry both.
# Hibernation works on GZ302EA / BIOS 314 / linux-cachyos 7.3 with the MT7925
# hook from Phase 22. See docs/hibernation.md, including how to tell a real
# resume from a failed attempt.

HIBERNATION_SWAPFILE="/swap/swapfile"
HIBERNATION_RESUME_DROPIN="$LIMINE_DROPIN_DIR/resume.conf"
HIBERNATION_RESUME_HOOK_CONF="/etc/mkinitcpio.conf.d/omarchy_resume.conf"

# resume=/resume_offset= as configured in the drop-in. Prints "device offset".
hibernation_configured_resume() {
    [[ -f "$HIBERNATION_RESUME_DROPIN" ]] || return 1
    local line dev off
    line=$(<"$HIBERNATION_RESUME_DROPIN")
    dev=$(grep -oE 'resume=[^ "]+' <<<"$line" | head -1); dev=${dev#resume=}
    off=$(grep -oE 'resume_offset=[0-9]+' <<<"$line" | head -1); off=${off#resume_offset=}
    [[ -n "$dev" && -n "$off" ]] || return 1
    printf '%s %s\n' "$dev" "$off"
}

phase21_check() {
    has_command omarchy-hibernation-available && omarchy-hibernation-available || return 1
    grep -qx 'HOOKS+=(resume)' "$HIBERNATION_RESUME_HOOK_CONF" 2>/dev/null || return 1

    # The running kernel must have been told where the image goes, and that
    # must match the drop-in. (The physical offset needs root to read; the run
    # step compares it.)
    local configured off
    configured=$(hibernation_configured_resume) || return 1
    off=${configured#* }
    grep -qw "resume_offset=$off" /proc/cmdline 2>/dev/null || return 1
    [[ "$(cat /sys/power/resume_offset 2>/dev/null)" == "$off" ]] || return 1
    [[ "$(cat /sys/power/resume 2>/dev/null)" != "0:0" ]]
}

phase21_run() {
    if ! has_command omarchy-hibernation-setup; then
        error "omarchy-hibernation-setup not found; this phase relies on Omarchy's hibernation tooling."
        return 1
    fi

    local mem_gb
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    info "Hibernation uses a swapfile the size of RAM (~${mem_gb} GiB) on the root filesystem."

    ensure_limine_dropins_effective || return 1

    # 1. Omarchy's setup: subvolume, swapfile, fstab, resume hook, resume.conf,
    #    rtc-alarm.conf, keyboard-backlight sleep hook. --no-rebuild because the
    #    rebuild below is verified; --force skips its own gum prompts.
    info "Running omarchy-hibernation-setup..."
    run_cmd omarchy-hibernation-setup --force --no-rebuild || {
        error "omarchy-hibernation-setup failed."
        return 1
    }

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would compare resume_offset with: sudo btrfs inspect-internal map-swapfile -r $HIBERNATION_SWAPFILE"
        rebuild_limine_and_verify "resume_offset=<offset>"
        NEEDS_REBOOT=1
        return 0
    fi

    # 2. resume_offset must match where the swapfile actually is.
    local actual configured dev off
    actual=$(sudo btrfs inspect-internal map-swapfile -r "$HIBERNATION_SWAPFILE" 2>/dev/null) || actual=""
    if [[ ! "$actual" =~ ^[0-9]+$ ]]; then
        error "Could not read the physical offset of $HIBERNATION_SWAPFILE."
        return 1
    fi

    if configured=$(hibernation_configured_resume); then
        dev=${configured% *}
        off=${configured#* }
    else
        dev=$(findmnt -no SOURCE -T "$HIBERNATION_SWAPFILE" | sed 's/\[.*\]//')
        off=""
    fi

    if [[ "$off" != "$actual" ]]; then
        warn "resume_offset in $HIBERNATION_RESUME_DROPIN is '${off:-missing}', swapfile is at $actual. Rewriting it."
        [[ -f "$HIBERNATION_RESUME_DROPIN" ]] \
            && sudo cp "$HIBERNATION_RESUME_DROPIN" "${HIBERNATION_RESUME_DROPIN}.bak.rog-z13.$(date +%s)"
        printf 'KERNEL_CMDLINE[default]+=" resume=%s resume_offset=%s"\n' "$dev" "$actual" \
            | sudo tee "$HIBERNATION_RESUME_DROPIN" >/dev/null
    else
        success "resume_offset matches the swapfile ($actual)."
    fi

    # 3. Rebuild and prove the next boot will carry both parameters.
    rebuild_limine_and_verify "resume=$dev" "resume_offset=$actual" || return 1

    if ! swapon --show=NAME --noheadings | grep -qxF "$HIBERNATION_SWAPFILE"; then
        warn "$HIBERNATION_SWAPFILE is not active swap; omarchy-hibernation-available will stay false until it is."
    fi

    NEEDS_REBOOT=1
    warn "Reboot, then test once: systemctl hibernate -> powers off -> press power -> Limine -> LUKS passphrase -> session restored."
    info "How to confirm it was a real resume (not a rolled-back attempt): docs/hibernation.md"
}
