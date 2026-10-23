#!/bin/bash
# Phase 3: Hardware Support (Firmware, Tablet utils, Wi-Fi fix)

# Critical firmware packages for ROG Z13 — must be explicitly installed
# to survive omarchy's orphan package cleanup
FIRMWARE_PKGS=(linux-firmware-amdgpu linux-firmware-mediatek linux-firmware-intel linux-firmware-whence linux-firmware-cirrus)

# Hyprland 0.55+ with the Lua config parser rejects `hyprctl keyword`, which is
# what iio-hyprland-git builds before r93 emitted. Upstream master switched to
# `hyprctl eval` (hl.monitor/hl.config), so a Lua-capable build is the marker
# that the package is new enough to drive rotation on Quattro.
iio_hyprland_is_lua_capable() {
    [[ -x /usr/bin/iio-hyprland ]] \
        && strings /usr/bin/iio-hyprland 2>/dev/null | grep -q 'hyprctl eval'
}

phase3_check() {
    # Check firmware packages are installed AND explicitly marked
    for pkg in "${FIRMWARE_PKGS[@]}"; do
        is_pkg_installed "$pkg" && is_pkg_explicit "$pkg" || return 1
    done
    
    is_pkg_installed iio-hyprland-git \
        && iio_hyprland_is_lua_capable \
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
        && [[ ! -f ~/.config/omarchy/hooks/post-update.d/z13-power-profile-debounce-hook.sh ]] \
        && [[ -x ~/.local/bin/omarchy-powerprofiles-set ]] \
        && [[ ! -d ~/.config/omarchy/plugins/z13.battery ]] \
        && [[ ! -d ~/.config/omarchy/plugins/z13.lock ]]
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

    # Install AUR packages. iio-hyprland-git is rebuilt (not just installed) when
    # the existing build predates Lua support: the AUR package tracks upstream
    # master, so a stale binary is the only reason rotation breaks on Quattro.
    local aur_pkgs=()
    if ! is_pkg_installed iio-hyprland-git; then
        aur_pkgs+=(iio-hyprland-git)
    elif ! iio_hyprland_is_lua_capable; then
        warn "iio-hyprland build predates Hyprland Lua support — rebuilding from AUR..."
        aur_pkgs+=(iio-hyprland-git)
    fi
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

    # Power-profile churn: legacy cleanup + the current user-level fix.
    #
    # The Z13's EC reports spurious line-power state. AC0.online — and therefore
    # UPower.onBattery — flaps:
    #   * a few times per few minutes while charging near the top of the range,
    #   * at roughly 1 Hz under heavy load while charging on an under-rated
    #     supply (a 140 W SlimQ; the Z13 ships with a 200 W adapter).
    #
    # Omarchy 3 reacted in udev rules keyed on the Mains supply, which caused a
    # profile set -> asusd fan-curve rewrite + notification + Wi-Fi power-save
    # churn on every flap. Quattro moved the switch into Quickshell
    # (plugins/services/battery/Service.qml watches UPower.onBatteryChanged and
    # calls omarchy-powerprofiles-set). A 2026-09-16 measurement showed no flap
    # and the old machinery was retired, but the flap returned: both the mild
    # charging case and the load-while-charging storm flip the profile.
    #
    # The fix is now a user-level wrapper, ~/.local/bin/omarchy-powerprofiles-set,
    # installed below. It keys on BAT0.status (actual power flow) and only acts
    # once that has settled, so a flap that returns to where it started changes
    # nothing and a sustained storm changes nothing. ~/.config/hypr/z13.lua
    # (Phase 4) puts ~/.local/bin ahead of /usr/share/omarchy/bin on the
    # compositor PATH so the shell, session autostart and DeckShift all resolve
    # it. No udev rule, no root, no RUN+=.
    #
    # This step is deliberately unconditional and idempotent: re-running the repo
    # removes any legacy udev/root machinery and refreshes the wrapper.
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
        success "No legacy power-profile udev machinery present."
    fi

    # Retire the earlier clone-the-whole-service approach (z13.battery/z13.lock).
    # Both forked a first-party shell service and drifted whenever Omarchy
    # changed it; z13.lock is obsolete now that 4.0.6 routes the lock decisions
    # through the fresh currentlyLocked() read, and z13.battery misses 4.5's
    # cross-service powerSaverOnBattery property. Best effort: disable through
    # the shell when it is running, then drop the plugin directory.
    local legacy_clone
    for legacy_clone in \
        "$HOME/.config/omarchy/plugins/z13.battery" \
        "$HOME/.config/omarchy/plugins/z13.lock"; do
        [[ -e $legacy_clone ]] || continue
        info "Removing retired service clone $(basename "$legacy_clone")..."
        if has_command omarchy-plugin-disable; then
            omarchy-plugin-disable "$(basename "$legacy_clone")" >/dev/null 2>&1 || true
        fi
        run_cmd rm -rf "$legacy_clone"
        success "Retired clone $(basename "$legacy_clone") removed."
    done

    # Install the debounced power-profile wrapper. It shadows the packaged
    # /usr/bin/omarchy-powerprofiles-set via the PATH prepend in z13.lua.
    local pp_wrapper_src="$SCRIPT_DIR/templates/omarchy-powerprofiles-set-debounced"
    local pp_wrapper_dst="$HOME/.local/bin/omarchy-powerprofiles-set"
    if [[ -f $pp_wrapper_src ]]; then
        if [[ ! -f $pp_wrapper_dst ]] || ! cmp -s "$pp_wrapper_src" "$pp_wrapper_dst"; then
            info "Installing debounced omarchy-powerprofiles-set wrapper..."
            run_cmd mkdir -p "$HOME/.local/bin"
            run_cmd install -m 0755 "$pp_wrapper_src" "$pp_wrapper_dst"
            success "Power-profile wrapper installed."
        else
            success "Power-profile wrapper up to date."
        fi
    else
        warn "Power-profile wrapper template missing ($pp_wrapper_src)."
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
