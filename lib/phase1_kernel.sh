#!/bin/bash
# Phase 1: Kernel & Drivers (CachyOS repos, Hyprland fix, kernel, ASUS tools)

phase1_check() {
    file_contains /etc/pacman.conf "[cachyos]" \
        && is_pkg_installed linux-cachyos \
        && file_contains /etc/pacman.conf "[g14]" \
        && is_pkg_installed asusctl
}

phase1_run() {
    local made_changes=false

    # 1. Install CachyOS repos if not present
    if ! file_contains /etc/pacman.conf "[cachyos]"; then
        info "Installing CachyOS repositories..."
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would download and run cachyos-repo.sh"
        else
            local tmpdir
            tmpdir=$(mktemp -d)
            curl -sL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o "$tmpdir/cachyos-repo.tar.xz"
            tar xf "$tmpdir/cachyos-repo.tar.xz" -C "$tmpdir"
            # The script inside may try to update and fail — that's expected
            sudo "$tmpdir/cachyos-repo/cachyos-repo.sh" || true
            rm -rf "$tmpdir"
        fi
        made_changes=true
        success "CachyOS repos installed."
    else
        success "CachyOS repos already present."
    fi

    # 2. Hyprland dependency fix — realign to stable repos then restore
    if ! is_pkg_installed linux-cachyos; then
        info "Resolving Hyprland dependencies before kernel install..."
        local backup
        backup="/etc/pacman.conf.bak.rog-z13.$(date +%s)"
        run_sudo cp /etc/pacman.conf "$backup"
        info "Backed up pacman.conf to $backup"

        # Temporarily comment out CachyOS sections
        run_sudo sed -i '/^\[cachyos/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-v3\]/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-v4\]/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-core-v3\]/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-core-v4\]/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-extra-v3\]/,/^$/s/^/#/' /etc/pacman.conf
        run_sudo sed -i '/^\[cachyos-extra-v4\]/,/^$/s/^/#/' /etc/pacman.conf

        info "Syncing to stable repos (this may take a moment)..."
        run_sudo pacman -Syyu

        info "Reinstalling Hyprland from stable repos..."
        run_sudo pacman -S --noconfirm hyprland hyprlock hyprtoolkit

        # Restore original pacman.conf (with CachyOS enabled)
        run_sudo cp "$backup" /etc/pacman.conf
        success "Hyprland dependencies resolved, CachyOS repos re-enabled."
    fi

    # 3. Install CachyOS kernel if not installed
    if ! is_pkg_installed linux-cachyos; then
        info "Installing CachyOS kernel and headers..."
        run_sudo pacman -S --noconfirm linux-cachyos linux-cachyos-headers
        made_changes=true
        success "CachyOS kernel installed."
    else
        success "CachyOS kernel already installed."
    fi

    # 4. Add G14 repo and install ASUS tools if not present
    if ! file_contains /etc/pacman.conf "[g14]"; then
        info "Adding G14 repository..."
        run_sudo_tee /etc/pacman.conf "\n[g14]\nServer = https://arch.asus-linux.org"
        run_sudo pacman-key --recv-keys 8F654886F17D497FEFE3DB448B15A6B0E9A3FA35
        run_sudo pacman-key --lsign-key 8F654886F17D497FEFE3DB448B15A6B0E9A3FA35
        success "G14 repo added and keys imported."
    else
        success "G14 repo already present."
    fi

    if ! is_pkg_installed asusctl; then
        info "Installing asusctl and rog-control-center..."
        run_sudo pacman -Sy --noconfirm asusctl rog-control-center
        made_changes=true
        success "ASUS tools installed."
    else
        success "ASUS tools already installed."
    fi

    if $made_changes; then
        NEEDS_REBOOT=1
    fi
}
