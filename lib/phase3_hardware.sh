#!/bin/bash
# Phase 3: Hardware Support (Firmware, Tablet utils, Wi-Fi fix)

# Critical firmware packages for ROG Z13 — must be explicitly installed
# to survive omarchy's orphan package cleanup
FIRMWARE_PKGS=(linux-firmware-amdgpu linux-firmware-mediatek linux-firmware-intel linux-firmware-whence linux-firmware-cirrus)

phase3_check() {
    # Check firmware packages are installed AND explicitly marked
    for pkg in "${FIRMWARE_PKGS[@]}"; do
        is_pkg_installed "$pkg" && is_pkg_explicit "$pkg" || return 1
    done
    
    is_pkg_installed iio-hyprland-git \
        && is_pkg_installed wvkbd-deskintl \
        && is_pkg_installed rofi-wayland \
        && [[ -f /etc/modprobe.d/mt7925e.conf ]] \
        && is_pkg_installed alsa-utils \
        && [[ -f /var/lib/alsa/asound.state ]]
}

phase3_run() {
    # Install any missing firmware packages
    local missing_fw=()
    for pkg in "${FIRMWARE_PKGS[@]}"; do
        is_pkg_installed "$pkg" || missing_fw+=("$pkg")
    done

    if [[ ${#missing_fw[@]} -gt 0 ]]; then
        info "Installing firmware packages: ${missing_fw[*]}..."
        run_sudo pacman -S --noconfirm "${missing_fw[@]}"
        success "Firmware packages installed."
    else
        success "Firmware packages already installed."
    fi

    # Mark ALL firmware as explicitly installed (protects from orphan cleanup)
    # This is critical: omarchy-update-orphan-pkgs removes packages installed
    # as dependencies if nothing requires them, which breaks WiFi and GPU
    local needs_explicit=()
    for pkg in "${FIRMWARE_PKGS[@]}"; do
        is_pkg_explicit "$pkg" || needs_explicit+=("$pkg")
    done

    if [[ ${#needs_explicit[@]} -gt 0 ]]; then
        info "Marking firmware as explicitly installed: ${needs_explicit[*]}..."
        run_sudo pacman -D --asexplicit "${needs_explicit[@]}"
        success "Firmware packages protected from orphan cleanup."
    fi

    # Remove legacy linux-firmware-git if present (conflicts with split packages)
    if is_pkg_installed linux-firmware-git; then
        warn "linux-firmware-git is installed (obsolete — split packages are now used)."
        if ask_yn "Remove linux-firmware-git?"; then
            run_sudo pacman -Rdd --noconfirm linux-firmware-git
            success "Removed linux-firmware-git."
        else
            warn "Keeping linux-firmware-git. You may encounter file conflicts."
        fi
    fi

    # Ensure yay is available for AUR packages
    if ! has_command yay; then
        warn "yay not found — installing yay-bin from AUR..."
        local tmpdir
        tmpdir=$(mktemp -d)
        run_cmd git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would run: makepkg -si --noconfirm (in $tmpdir/yay-bin)"
        else
            (cd "$tmpdir/yay-bin" && makepkg -si --noconfirm)
        fi
        rm -rf "$tmpdir"
        success "yay installed."
    fi

    # Install AUR packages
    local aur_pkgs=()
    is_pkg_installed iio-hyprland-git || aur_pkgs+=(iio-hyprland-git)
    is_pkg_installed wvkbd-deskintl   || aur_pkgs+=(wvkbd-deskintl)
    is_pkg_installed rofi-wayland     || aur_pkgs+=(rofi-wayland)

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        info "Installing AUR packages: ${aur_pkgs[*]}..."
        run_cmd yay -S --noconfirm "${aur_pkgs[@]}"
        success "Tablet utilities installed."
    else
        success "Tablet utilities already installed."
    fi

    # Wi-Fi stability fix
    if [[ ! -f /etc/modprobe.d/mt7925e.conf ]]; then
        info "Creating Wi-Fi stability fix..."
        run_sudo_tee /etc/modprobe.d/mt7925e.conf "options mt7925e disable_aspm=1"
        success "Wi-Fi fix applied."
    else
        success "Wi-Fi fix already in place."
    fi

    # Speaker amp initialization (ALC294 + CS35L41)
    # Omarchy's soft-mixer config requires hardware volume to be set manually
    if ! is_pkg_installed alsa-utils; then
        info "Installing alsa-utils for mixer control..."
        run_sudo pacman -S --noconfirm alsa-utils
    fi

    info "Initializing speaker amplifier volume..."
    run_cmd amixer -c 1 set "Master" 100% unmute
    run_cmd amixer -c 1 set "Speaker" 100% unmute
    run_sudo alsactl store 1
    success "Speaker amp initialized."
}
