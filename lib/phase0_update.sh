#!/bin/bash
# Phase 0: System Update

phase0_check() {
    local up_to_date=true

    # Pending package updates, not counting IgnorePkg entries (pacman lists
    # them as "[ignored]"; an update cannot install them). Omarchy itself is a
    # pacman package, so this covers it too.
    if pacman -Qu 2>/dev/null | grep -v '\[ignored\]$' | grep -q .; then
        up_to_date=false
    fi

    $up_to_date
}

phase0_run() {
    info "Updating system keyrings and packages..."
    run_sudo pacman -Sy --noconfirm archlinux-keyring
    run_sudo pacman -Syu
    NEEDS_REBOOT=1
    success "System updated."
}
