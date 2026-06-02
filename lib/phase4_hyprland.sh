#!/bin/bash
# Phase 4: Hyprland Configuration

HYPRLAND_CONF="$HOME/.config/hypr/hyprland.conf"

SYSTEM_SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-asus-z13-touchpad-reset"

phase4_check() {
    file_contains "$HYPRLAND_CONF" "wvkbd-deskintl" \
        && [[ -x "$SYSTEM_SLEEP_HOOK" ]]
}

phase4_run() {
    if [[ ! -f "$HYPRLAND_CONF" ]]; then
        warn "Hyprland config not found at $HYPRLAND_CONF — skipping."
        return
    fi

    info "Appending Z13 configuration to hyprland.conf..."
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would append templates/hyprland-z13.conf to $HYPRLAND_CONF"
    else
        echo "" >> "$HYPRLAND_CONF"
        cat "$SCRIPT_DIR/templates/hyprland-z13.conf" >> "$HYPRLAND_CONF"
    fi
    success "Hyprland config updated."

    # Deploy profile change notification script
    local notify_script="$HOME/.local/bin/rog-profile-notify.sh"
    info "Installing profile notification script..."
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would install rog-profile-notify.sh to $notify_script"
    else
        mkdir -p "$HOME/.local/bin"
        cp "$SCRIPT_DIR/templates/rog-profile-notify.sh" "$notify_script"
        chmod +x "$notify_script"
    fi
    success "Profile notification script installed."

    # Set named eDP-1 monitor for Z13 (required for iio-hyprland auto-rotation
    # and omarchy scaling cycle to work correctly with hyprctl keywords)
    local monitors_conf="$HOME/.config/hypr/monitors.conf"
    if [[ -f $monitors_conf ]] && grep -q '^monitor=,preferred,auto,' "$monitors_conf"; then
        info "Setting named eDP-1 monitor and auto-rotation in monitors.conf..."
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would replace catch-all monitor line with eDP-1 and add iio-hyprland"
        else
            sed -i 's|^monitor=,preferred,auto,.*|monitor=eDP-1,preferred,auto,2|' "$monitors_conf"
            if ! grep -q 'iio-hyprland' "$monitors_conf"; then
                sed -i '/^monitor=eDP-1,preferred,auto,2$/a exec-once = iio-hyprland' "$monitors_conf"
            fi
        fi
        success "Monitor config updated."
    fi

    # Install systemd sleep hook to reset USB keyboard dock after resume.
    # The AMD xHCI controller intermittently crashes during resume, causing
    # the ELAN touchpad firmware to re-enumerate with corrupted multi-touch
    # state (gestures require +1 finger). This forces a clean reinitialization.
    info "Installing systemd sleep hook for touchpad resume fix..."
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would install $SYSTEM_SLEEP_HOOK"
    else
        run_sudo cp "$SCRIPT_DIR/templates/system-sleep-touchpad-reset.sh" "$SYSTEM_SLEEP_HOOK"
        run_sudo chmod +x "$SYSTEM_SLEEP_HOOK"
    fi
    success "Sleep hook installed."

    # Update hypridle after_sleep_cmd to include hyprctl reload as a safety net
    local hypridle_conf="$HOME/.config/hypr/hypridle.conf"
    if [[ -f "$hypridle_conf" ]]; then
        info "Updating hypridle after_sleep_cmd to include hyprctl reload..."
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would update after_sleep_cmd in $hypridle_conf"
        else
            sed -i 's|after_sleep_cmd = sleep 1 && omarchy-system-wake|after_sleep_cmd = sleep 1 \&\& omarchy-system-wake \&\& hyprctl reload|' "$hypridle_conf"
        fi
        success "hypridle.conf updated."
    fi
}
