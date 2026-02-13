#!/bin/bash
# Phase 4: Hyprland Configuration

HYPRLAND_CONF="$HOME/.config/hypr/hyprland.conf"

phase4_check() {
    file_contains "$HYPRLAND_CONF" "ASUS ROG Flow Z13"
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
}
