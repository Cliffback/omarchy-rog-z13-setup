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
        && [[ ! -f ~/.config/wireplumber/wireplumber.conf.d/alsa-soft-mixer.conf ]] \
        && [[ -L "$HOME/.config/makima/Asus Keyboard.toml" ]]
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

    # Audio fix: Remove Omarchy's soft-mixer config
    # With soft-mixer enabled, PipeWire doesn't manage ALSA hardware switches,
    # causing speaker/headphone switching to break on jack plug/unplug.
    # See: https://github.com/basecamp/omarchy/issues/4821
    if [[ -f ~/.config/wireplumber/wireplumber.conf.d/alsa-soft-mixer.conf ]]; then
        info "Removing soft-mixer config (breaks headphone/speaker switching)..."
        rm -f ~/.config/wireplumber/wireplumber.conf.d/alsa-soft-mixer.conf
        info "Restarting WirePlumber..."
        systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
        success "Audio fix applied."
    fi

    # Speaker amp initialization (ALC294 + CS35L41)
    if ! is_pkg_installed alsa-utils; then
        info "Installing alsa-utils for mixer control..."
        run_sudo pacman -S --noconfirm alsa-utils
    fi

    # Initial unmute for first boot (PipeWire manages persistence via WirePlumber)
    # Dynamically find the card with ALC294 codec (Z13's Realtek chip)
    local card
    card=$(aplay -l 2>/dev/null | grep -i "ALC294" | head -1 | sed 's/card \([0-9]*\).*/\1/')
    if [[ -n $card ]]; then
        info "Initializing speaker amplifier volume (card $card)..."
        run_cmd amixer -c "$card" set Master 80% unmute
        run_cmd amixer -c "$card" set Speaker unmute
        run_cmd amixer -c "$card" set Headphone unmute
        success "Speaker amp initialized."
    else
        warn "ALC294 codec not found — skipping mixer init"
    fi

    # Makima Copilot key remap for ASUS keyboard
    # ASUS ROG devices with detachable keyboards use "Asus Keyboard" as the device
    # name instead of "AT Translated Set 2 keyboard". Create a symlink so makima
    # recognizes both device names.
    # See: https://github.com/basecamp/omarchy/pull/4935 (can be removed if merged)
    local makima_src="$HOME/.config/makima/AT Translated Set 2 keyboard.toml"
    local makima_dst="$HOME/.config/makima/Asus Keyboard.toml"

    if [[ -f "$makima_src" ]] && [[ ! -e "$makima_dst" ]]; then
        info "Creating makima symlink for ASUS keyboard..."
        run_cmd ln -sf "AT Translated Set 2 keyboard.toml" "$makima_dst"
        success "Makima ASUS keyboard support configured."
    elif [[ -L "$makima_dst" ]]; then
        success "Makima ASUS keyboard symlink already exists."
    elif [[ ! -f "$makima_src" ]]; then
        warn "Makima base config not found — skipping ASUS keyboard symlink."
    fi
}
