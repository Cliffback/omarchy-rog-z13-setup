#!/bin/bash
# Phase 0: System Update

phase0_check() {
    local up_to_date=true

    # Check for pending package updates
    if pacman -Qu 2>/dev/null | grep -q .; then
        up_to_date=false
    fi

    # Check omarchy version against latest release
    if has_command omarchy-version; then
        local current latest
        current=$(omarchy-version 2>/dev/null || echo "unknown")
        latest=$(curl -sf "https://api.github.com/repos/basecamp/omarchy/releases/latest" \
            | grep -oP '"tag_name":\s*"\K[^"]+' 2>/dev/null || echo "unknown")
        latest="${latest#v}"
        if [[ "$current" != "unknown" && "$latest" != "unknown" && "$current" != "$latest" ]]; then
            up_to_date=false
        fi
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
