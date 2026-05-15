#!/bin/bash
# Phase 4: Hyprland Configuration

HYPRLAND_CONF="$HOME/.config/hypr/hyprland.conf"

phase4_check() {
    file_contains "$HYPRLAND_CONF" "XF86Launch3"
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
}
