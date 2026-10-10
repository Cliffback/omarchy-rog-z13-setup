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

# Debounced clone of Omarchy's omarchy.battery shell service (see phase3_run).
Z13_BATTERY_ID="z13.battery"
Z13_BATTERY_SRC="$SCRIPT_DIR/templates/omarchy-plugins/$Z13_BATTERY_ID"
Z13_BATTERY_DST="$HOME/.config/omarchy/plugins/$Z13_BATTERY_ID"
Z13_BATTERY_UPSTREAM="$HOME/.local/share/omarchy/shell/plugins/services/battery"
OMARCHY_SHELL_JSON="$HOME/.config/omarchy/shell.json"
Z13_BATTERY_FILES=(manifest.json Service.qml BatteryModel.js)

z13_battery_files_current() {
    local f
    for f in "${Z13_BATTERY_FILES[@]}"; do
        cmp -s "$Z13_BATTERY_SRC/$f" "$Z13_BATTERY_DST/$f" || return 1
    done
}

# Enabled = listed in plugins[] with the built-in recorded in disabledPlugins[],
# which is exactly what `omarchy-plugin-enable` writes for a service clone.
z13_battery_enabled() {
    [[ -f $OMARCHY_SHELL_JSON ]] && jq -e --arg id "$Z13_BATTERY_ID" '
        any(.plugins[]?; .id == $id)
        and any(.disabledPlugins[]?; . == "omarchy.battery")
    ' "$OMARCHY_SHELL_JSON" >/dev/null 2>&1
}

# The clone freezes upstream Service.qml/BatteryModel.js. Warn (don't fail) when
# Omarchy ships a different revision so upstream fixes get folded back in.
z13_battery_warn_upstream_drift() {
    [[ -d $Z13_BATTERY_UPSTREAM ]] || return 0
    if ! (cd "$Z13_BATTERY_UPSTREAM" && sha256sum --quiet -c "$Z13_BATTERY_SRC/upstream.sha256") &>/dev/null; then
        warn "Omarchy's omarchy.battery service changed since z13.battery was cloned."
        warn "Diff $Z13_BATTERY_UPSTREAM against $Z13_BATTERY_SRC, port upstream changes,"
        warn "then refresh templates/omarchy-plugins/$Z13_BATTERY_ID/upstream.sha256."
    fi
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
        && z13_battery_files_current \
        && z13_battery_enabled
}

phase3_deploy_z13_battery() {
    if [[ ! -d $Z13_BATTERY_UPSTREAM ]]; then
        warn "Omarchy battery service not found ($Z13_BATTERY_UPSTREAM) — skipping z13.battery."
        return 0
    fi
    z13_battery_warn_upstream_drift

    local changed=0
    if z13_battery_files_current; then
        success "z13.battery plugin files up to date."
    else
        info "Installing debounced battery service to $Z13_BATTERY_DST..."
        run_cmd mkdir -p "$Z13_BATTERY_DST"
        local f
        for f in "${Z13_BATTERY_FILES[@]}"; do
            run_cmd cp "$Z13_BATTERY_SRC/$f" "$Z13_BATTERY_DST/$f"
        done
        success "z13.battery plugin files installed."
        changed=1
    fi

    if z13_battery_enabled; then
        success "z13.battery enabled (omarchy.battery disabled)."
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: omarchy-shell shell rescanPlugins && omarchy-plugin-enable $Z13_BATTERY_ID"
    elif ! has_command omarchy-plugin-enable; then
        warn "omarchy-plugin-enable not found — enable manually: omarchy-plugin-enable $Z13_BATTERY_ID"
        return 0
    else
        # Enabling goes through the running shell so it writes plugins[],
        # disabledPlugins[] and cloneSourceRestores[] coherently; revert with
        # `omarchy-plugin-disable z13.battery`.
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        local attempt
        for (( attempt = 0; attempt < 40; attempt++ )); do
            omarchy-plugin-list --json 2>/dev/null \
                | jq -e --arg id "$Z13_BATTERY_ID" 'any(.[]; .id == $id)' >/dev/null && break
            sleep 0.1
        done
        if omarchy-plugin-enable "$Z13_BATTERY_ID" >/dev/null 2>&1 && z13_battery_enabled; then
            success "z13.battery enabled; omarchy.battery disabled."
            changed=1
        else
            warn "Could not enable z13.battery (is the Omarchy shell running?)."
            warn "Run after login: omarchy-plugin-enable $Z13_BATTERY_ID && omarchy-restart-shell"
            return 0
        fi
    fi

    # The shell's live plugin reload does not re-instantiate a changed or newly
    # enabled service; a restart does. Confirm it loaded with:
    #   journalctl -b -t z13-battery
    if (( changed )) && has_command omarchy-restart-shell; then
        info "Restarting the Omarchy shell to load z13.battery..."
        run_cmd omarchy-restart-shell >/dev/null \
            || warn "Shell restart failed — run: omarchy-restart-shell"
    fi
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

    # Power-profile churn fix (AC0 flap).
    #
    # The EC on this machine toggles AC0.online 0 <-> 1 spuriously while
    # charging, without an ACPI notify. Two regimes:
    #   - mild: a few flaps every 3-4 min near full charge at light load;
    #   - severe: ~1 Hz under heavy load while charging on the 140 W SlimQ
    #     supply (stock is 200 W), with BAT0.status and UPower.onBattery
    #     flapping in lockstep.
    # Anything keyed on the AC line inherits it. Each flap flipped the profile
    # Performance <-> Balanced, and asusd rewrote the fan curve every time
    # (98 writes in one boot on 2026-10-10). Dropping to Balanced lowers draw,
    # which plausibly re-stabilises AC0 and keeps the severe storm oscillating.
    #
    # History: Omarchy 3 drove switching from udev rules; the fix re-keyed them
    # onto BAT0.status behind a debounce wrapper. Quattro moved switching into
    # Quickshell (omarchy.battery: UPower.onBatteryChanged ->
    # omarchy-powerprofiles-set). A single 2026-09-16 charge window measured
    # zero flaps, so the fix was retired; the flap is intermittent and that
    # measurement missed it. BAT0.status is not a safe key either, because it
    # also flaps under load.
    #
    # Current fix: z13.battery, a user-config clone of omarchy.battery whose
    # profile switch fires only after UPower.onBattery has been stable for
    # 15 s. It lives in ~/.config/omarchy/plugins, so it survives Omarchy
    # updates and needs no root. omarchy-plugin-enable disables the built-in.
    #
    # The Omarchy 3 machinery is still removed below, because it would fail
    # against root-owned /usr/share/omarchy.
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

    phase3_deploy_z13_battery

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
