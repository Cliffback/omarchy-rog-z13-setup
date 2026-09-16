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
        && [[ -f ~/.config/wireplumber/wireplumber.conf.d/hdmi-audio-autoactivate.conf ]] \
        && [[ ! -f /etc/udev/rules.d/99-power-profile.rules ]] \
        && [[ ! -f /etc/udev/rules.d/99-power-profile.rules.omarchy-disabled ]] \
        && [[ ! -f /etc/udev/rules.d/99-wifi-powersave.rules ]] \
        && [[ ! -f ~/.local/bin/z13-wifi-powersave-auto ]] \
        && [[ ! -f ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh ]]
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

    # Power-profile churn fix: RETIRED under Omarchy 4 (Quattro).
    #
    # Under Omarchy 3, profile switching lived in udev rules keyed on the AC
    # "Mains" supply. On this machine AC0.online flaps 0 <-> 1 every 1-3
    # seconds while the battery is actively charging, so each event triggered a
    # profile set -> asusd fan-curve rewrite (momentary fan stop), notification
    # spam, and Wi-Fi power-save churn (proven: 205 debounce invocations and
    # 101 wifi-powersave runs in 14 minutes while capacity rose monotonically).
    # The fix re-keyed those rules onto BAT0.status and wrapped the profile
    # script in a debounce.
    #
    # Quattro deleted the udev rules and moved profile switching into
    # Quickshell: plugins/services/battery/Service.qml watches
    # UPower.onBatteryChanged and calls `omarchy-powerprofiles-set`. Measured
    # on 2026-09-16 over a 36% -> 90% charge: AC0 and UPower.onBattery each
    # moved exactly once (at plug-in), with zero unpaired transitions, versus
    # 205 debounce invocations in 14 minutes under the old mechanism. The bug
    # does not exist under Quattro, so the debounce machinery is not just
    # unnecessary but actively harmful: ~/.local/share/omarchy is now a symlink
    # to root-owned /usr/share/omarchy, so the wrapper cannot be installed and
    # the udev rule fails on every battery event.
    #
    # This step therefore removes the retired machinery rather than installing
    # it. It is deliberately unconditional and idempotent: re-running the repo
    # on a machine that still carries the old fix cleans it up.
    local legacy_rules=(
        /etc/udev/rules.d/99-power-profile.rules
        /etc/udev/rules.d/99-power-profile.rules.omarchy-disabled
        /etc/udev/rules.d/99-wifi-powersave.rules
    )
    # Root-owned: ~/.local/share/omarchy is a symlink to /usr/share/omarchy on
    # Quattro, so this path needs sudo even though it reads as a home path.
    local legacy_root_files=(
        "$HOME/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced"
    )
    local legacy_files=(
        "$HOME/.local/bin/z13-wifi-powersave-auto"
        "$HOME/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh"
    )

    local removed_rules=() removed_files=() removed_root_files=()
    local f
    for f in "${legacy_rules[@]}"; do
        [[ -e $f ]] && removed_rules+=("$f")
    done
    for f in "${legacy_root_files[@]}"; do
        [[ -e $f ]] && removed_root_files+=("$f")
    done
    for f in "${legacy_files[@]}"; do
        [[ -e $f ]] && removed_files+=("$f")
    done

    if [[ ${#removed_rules[@]} -gt 0 || ${#removed_root_files[@]} -gt 0 ]]; then
        info "Removing retired power-profile udev rules (Quattro uses Quickshell)..."
        for f in "${removed_rules[@]}"; do
            run_sudo rm -f "$f"
        done
        for f in "${removed_root_files[@]}"; do
            run_sudo rm -f "$f"
        done
        [[ ${#removed_rules[@]} -gt 0 ]] && run_sudo udevadm control --reload-rules
        success "Retired udev rules removed."
    fi

    if [[ ${#removed_files[@]} -gt 0 ]]; then
        info "Removing retired power-profile helpers..."
        for f in "${removed_files[@]}"; do
            run_cmd rm -f "$f"
        done
        success "Retired helpers removed."
    fi

    if [[ ${#removed_rules[@]} -eq 0 && ${#removed_root_files[@]} -eq 0 && ${#removed_files[@]} -eq 0 ]]; then
        success "No legacy power-profile machinery present."
    fi

    # HDMI audio: Enable auto-profile for AMD HDMI controller
    # Without this, WirePlumber leaves the HDMI audio card profile set to "off"
    # and HDMI monitors never appear as audio output devices.
    local wp_conf_dir="$HOME/.config/wireplumber/wireplumber.conf.d"
    local hdmi_conf="$wp_conf_dir/hdmi-audio-autoactivate.conf"
    if [[ ! -f "$hdmi_conf" ]]; then
        info "Enabling HDMI audio auto-profile..."
        mkdir -p "$wp_conf_dir"
        cat > "$hdmi_conf" << 'EOF'
## Auto-activate HDMI audio output profiles.
## WirePlumber defaults api.acp.auto-profile to false, which leaves
## HDMI audio cards on the "off" profile — monitors never appear as
## audio outputs. This rule enables automatic profile selection for
## AMD/ATI HDMI audio controllers.

monitor.alsa.rules = [
  {
    matches = [
      {
        device.vendor.id = "0x1002"
      }
    ]
    actions = {
      update-props = {
        api.acp.auto-profile = true
        api.acp.auto-port = true
      }
    }
  }
]
EOF
        # Clear any stale "off" profile stored in WirePlumber state.
        # Without this, the state-profile hook restores "off" on every
        # restart, overriding the auto-profile config above.
        local wp_state="$HOME/.local/state/wireplumber/default-profile"
        if [[ -f "$wp_state" ]] && grep -q "alsa_card.pci-0000_c4_00.1=off" "$wp_state"; then
            info "Clearing stale HDMI 'off' profile from WirePlumber state..."
            sed -i '/alsa_card.pci-0000_c4_00.1=off/d' "$wp_state"
        fi

        systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
        success "HDMI audio auto-profile enabled."
    else
        success "HDMI audio auto-profile already configured."
    fi

}
