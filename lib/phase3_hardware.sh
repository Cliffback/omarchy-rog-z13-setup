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
        && [[ -f ~/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced ]] \
        && ! grep -q '__HOME__' ~/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced 2>/dev/null \
        && ! grep -q 'sleep 3' ~/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced 2>/dev/null \
        && grep -q 'find_system_battery' ~/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced 2>/dev/null \
        && [[ -x ~/.local/bin/z13-wifi-powersave-auto ]] \
        && [[ -f /etc/udev/rules.d/99-power-profile.rules ]] \
        && grep -q 'debounced' /etc/udev/rules.d/99-power-profile.rules 2>/dev/null \
        && ! grep -q '__HOME__' /etc/udev/rules.d/99-power-profile.rules 2>/dev/null \
        && grep -q 'KERNEL=="BAT\*"' /etc/udev/rules.d/99-power-profile.rules 2>/dev/null \
        && ! grep '^SUBSYSTEM' /etc/udev/rules.d/99-power-profile.rules 2>/dev/null | grep -q 'unit=omarchy-power-profile' \
        && [[ -f /etc/udev/rules.d/99-wifi-powersave.rules ]] \
        && grep -q 'KERNEL=="BAT\*"' /etc/udev/rules.d/99-wifi-powersave.rules 2>/dev/null \
        && ! grep '^SUBSYSTEM' /etc/udev/rules.d/99-wifi-powersave.rules 2>/dev/null | grep -q 'ATTR{status}' \
        && ! grep '^SUBSYSTEM' /etc/udev/rules.d/99-wifi-powersave.rules 2>/dev/null | grep -q 'unit=omarchy-wifi-powersave' \
        && [[ -f ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh ]] \
        && grep -q 'Re-keying' ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh 2>/dev/null
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

    # Power profile debounce: The Z13 generates spurious power_supply events.
    # AC0.online flaps 0 <-> 1 every 1-3 seconds while the battery is actively
    # charging (proven: the Mains-keyed wifi-powersave rule toggled 101 times in
    # 14 minutes while capacity rose monotonically 53% -> 64%). Each event
    # triggers a profile set -> asusd fan curve rewrite (momentary fan stop),
    # notification spam, and Wi-Fi power-save churn.
    #
    # v2 fix (2025-05-24): removed fixed --unit name from systemd-run (caused
    # boot-time collisions) and added flock + idempotency to the wrapper script.
    #
    # v6 fix (2026-09-15): key both udev rules on the system battery
    # (KERNEL=="BAT*", type=Battery) instead of Mains, because BAT0.status
    # reflects actual power flow and stays stable while AC0 flaps. The wrapper
    # script now reads BAT0.status (Discharging -> battery, else -> AC) and
    # keeps AC0 detection only as a fallback for machines without a battery.
    # v5's load-triggered diagnosis was wrong: 35 minutes of 32-thread load at
    # 90% charge produced zero events, while charging produced 205 in 14 min.
    local debounce_script="$HOME/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced"
    local debounce_rule="/etc/udev/rules.d/99-power-profile.rules"
    local wifi_rule="/etc/udev/rules.d/99-wifi-powersave.rules"
    local debounce_hook="$HOME/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh"

    # Reinstall script if missing, has template placeholders, is the old v1
    # version with a naive "sleep 3", or predates the v6 battery-based detection.
    if [[ ! -f "$debounce_script" ]] \
        || grep -q '__HOME__' "$debounce_script" 2>/dev/null \
        || grep -q 'sleep 3' "$debounce_script" 2>/dev/null \
        || ! grep -q 'find_system_battery' "$debounce_script" 2>/dev/null; then
        info "Installing debounced power profile switcher (v6, battery-keyed)..."
        mkdir -p "$HOME/.local/bin"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/templates/omarchy-powerprofiles-set-debounced" > "$debounce_script"
        chmod +x "$debounce_script"
        success "Debounce script installed."
    fi

    # Reinstall udev rule if missing, not debounced, has placeholders, still
    # uses the fixed --unit name, or is still keyed on Mains (AC0 flaps).
    if [[ ! -f "$debounce_rule" ]] \
        || ! grep -q 'debounced' "$debounce_rule" 2>/dev/null \
        || grep -q '__HOME__' "$debounce_rule" 2>/dev/null \
        || ! grep -q 'KERNEL=="BAT\*"' "$debounce_rule" 2>/dev/null \
        || grep '^SUBSYSTEM' "$debounce_rule" 2>/dev/null | grep -q 'unit=omarchy-power-profile'; then
        info "Installing debounced udev rule (battery-keyed, overrides Omarchy default)..."
        local tmpfile
        tmpfile=$(mktemp)
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/templates/99-power-profile.rules" > "$tmpfile"
        run_sudo cp "$tmpfile" "$debounce_rule"
        rm -f "$tmpfile"
        run_sudo udevadm control --reload-rules
        success "Debounced udev rule installed."
    fi

    # Wi-Fi power-save rule: Omarchy's version is Mains-keyed and therefore
    # inherits the AC0 flap, toggling Wi-Fi power save every 1-3 seconds while
    # charging. Re-key it onto the battery. A single rule fires a wrapper that
    # reads the settled BAT0.status itself, because matching ATTR{status}
    # directly in udev races the transition.
    local wifi_wrapper="$HOME/.local/bin/z13-wifi-powersave-auto"
    if [[ ! -x "$wifi_wrapper" ]]; then
        info "Installing battery-keyed wifi-powersave wrapper..."
        mkdir -p "$HOME/.local/bin"
        cp "$SCRIPT_DIR/templates/z13-wifi-powersave-auto.sh" "$wifi_wrapper"
        chmod +x "$wifi_wrapper"
        success "Wi-Fi power-save wrapper installed."
    fi

    if [[ ! -f "$wifi_rule" ]] \
        || grep -q '__HOME__' "$wifi_rule" 2>/dev/null \
        || ! grep -q 'KERNEL=="BAT\*"' "$wifi_rule" 2>/dev/null \
        || grep '^SUBSYSTEM' "$wifi_rule" 2>/dev/null | grep -q 'ATTR{status}' \
        || grep '^SUBSYSTEM' "$wifi_rule" 2>/dev/null | grep -q 'unit=omarchy-wifi-powersave'; then
        info "Installing battery-keyed wifi-powersave rule..."
        local wifi_tmp
        wifi_tmp=$(mktemp)
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/templates/99-wifi-powersave.rules" > "$wifi_tmp"
        run_sudo cp "$wifi_tmp" "$wifi_rule"
        rm -f "$wifi_tmp"
        run_sudo udevadm control --reload-rules
        success "Wi-Fi power-save rule installed."
    fi

    # Reinstall post-update hook if missing, or is an older version that only
    # handled the --unit name and not the Mains -> battery re-keying.
    if [[ ! -f "$debounce_hook" ]] \
        || ! grep -q 'Re-keying' "$debounce_hook" 2>/dev/null; then
        info "Installing post-update hook (survives Omarchy updates)..."
        mkdir -p "$(dirname "$debounce_hook")"
        cp "$SCRIPT_DIR/templates/z13-power-profile-debounce-hook.sh" "$debounce_hook"
        chmod +x "$debounce_hook"
        success "Post-update hook installed."
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
