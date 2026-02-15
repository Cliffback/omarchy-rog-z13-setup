#!/bin/bash
# Phase 7: CachyOS Mirror Optimization (optional)

phase7_check() {
    is_pkg_installed cachyos-rate-mirrors
}

phase7_run() {
    info "Optimizing CachyOS mirrors..."

    if ! is_pkg_installed cachyos-rate-mirrors; then
        run_sudo pacman -S --noconfirm cachyos-rate-mirrors
    fi

    info "Ranking mirrors (this may take a minute)..."
    run_sudo cachyos-rate-mirrors

    info "Refreshing package databases..."
    run_sudo pacman -Syy

    success "CachyOS mirror optimization complete."
}
