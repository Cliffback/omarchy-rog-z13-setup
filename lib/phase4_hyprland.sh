#!/bin/bash
# Phase 4: Hyprland Configuration
#
# Omarchy 4 (Quattro) moved Hyprland configuration from .conf to .lua. The Z13
# overrides live in a single user module, ~/.config/hypr/z13.lua, which is
# required from ~/.config/hypr/hyprland.lua. The old .conf append is dead on
# Quattro and is no longer written.

HYPR_DIR="$HOME/.config/hypr"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"
MONITORS_LUA="$HYPR_DIR/monitors.lua"
Z13_LUA="$HYPR_DIR/z13.lua"
Z13_REQUIRE='require("hypr.z13")'

NOTIFY_SCRIPT="$HOME/.local/bin/rog-profile-notify.sh"
IIO_WRAPPER="$HOME/.local/bin/iio-hyprland"

# Retired. Kept only so re-runs clean it up.
Z13_DOCK="$HOME/.local/bin/z13-dock-internal"
INTERNAL_DISABLE_FLAG="$HOME/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"

# The pre-Quattro Hyprland config. Omarchy 4's Lua provider never reads it, so
# once hyprland.lua exists it is dead weight — and actively misleading, since
# edits there appear to do nothing. Everything it held now lives in z13.lua.
DEAD_HYPRLAND_CONF="$HYPR_DIR/hyprland.conf"

# Z13 default scale for the internal panel, used only when monitors.lua still
# carries Omarchy's stock "auto". Omarchy's scaling keys (SUPER+SLASH and
# SUPER+ALT+SLASH) rewrite omarchy_monitor_scale and reload, so a number here is
# what makes them work; "auto" means PPI, which the keys then cannot express.
Z13_SCALE_DEFAULT=1.6

# Display config lives in Omarchy's own monitors.lua so the scaling keys drive
# the internal panel: the keys rewrite omarchy_monitor_scale, and both the
# catch-all and the eDP rule read that variable. z13.lua no longer pins any
# monitor, because a per-output rule that omits scale does NOT inherit the
# catch-all (Hyprland has no field-level merge) and would freeze the scale.
monitors_configured() {
    [[ -f "$MONITORS_LUA" ]] \
        && grep -qE '^local omarchy_monitor_scale = [0-9]' "$MONITORS_LUA" \
        && grep -qF 'output = "HDMI-A-1"' "$MONITORS_LUA"
}

phase4_check() {
    [[ -f "$Z13_LUA" ]] \
        && [[ -x "$NOTIFY_SCRIPT" ]] \
        && [[ -x "$IIO_WRAPPER" ]] \
        && [[ ! -e "$Z13_DOCK" ]] \
        && [[ ! -e "$INTERNAL_DISABLE_FLAG" ]] \
        && [[ ! -e "$DEAD_HYPRLAND_CONF" ]] \
        && monitors_configured \
        && file_contains "$HYPRLAND_LUA" "$Z13_REQUIRE"
}

# Insert the require line after the last of Omarchy's user-module requires, so
# it sits with the other personal overrides rather than inside the comment
# block above the toggles require. Falls back to just before the toggles
# require, then to the end of the file. Idempotent: callers check first.
add_z13_require() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would add $Z13_REQUIRE to $HYPRLAND_LUA"
        return
    fi

    awk -v line="$Z13_REQUIRE" '
        /^require\("hypr\.[a-z-]+"\)/ { last = NR }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last) { print line; done = 1 }
            }
            if (!done) print line
        }
    ' "$HYPRLAND_LUA" > "$HYPRLAND_LUA.tmp" && mv "$HYPRLAND_LUA.tmp" "$HYPRLAND_LUA"
}

# Give the internal panel a concrete default scale, but only when monitors.lua
# still has Omarchy's stock "auto" — a value the user picked with the scaling
# keys is never clobbered. GDK_SCALE is left alone: Omarchy's scaling command
# owns it (it rewrites omarchy_gdk_scale on every change).
set_monitors_scale_default() {
    if [[ ! -f "$MONITORS_LUA" ]]; then
        warn "Monitor config not found at $MONITORS_LUA — skipping scale fix."
        return
    fi

    if grep -qE '^local omarchy_monitor_scale = [0-9]' "$MONITORS_LUA"; then
        info "Monitor scale already set to a number — leaving it alone."
        return
    fi

    if grep -q '^local omarchy_monitor_scale = ' "$MONITORS_LUA"; then
        info "Setting monitor scale default to $Z13_SCALE_DEFAULT..."
        run_cmd sed -i -E \
            "s|^local omarchy_monitor_scale = .*|local omarchy_monitor_scale = $Z13_SCALE_DEFAULT|" \
            "$MONITORS_LUA"
        success "Monitor scale default set to $Z13_SCALE_DEFAULT."
    else
        warn "No omarchy_monitor_scale line in $MONITORS_LUA — leaving it alone."
    fi
}

# Append the Z13 monitor rules to Omarchy's monitors.lua, once. The catch-all
# above them already exists, so only the two per-output rules are added:
#   eDP-1     — anchored at the origin, scale from the variable the scaling keys
#               rewrite, so the keys drive the internal panel.
#   HDMI-A-1  — pinned to 3840x2160@120 (its EDID prefers 4K@60) at scale 1.25,
#               offset so its bottom-left corner meets the internal panel's
#               bottom-left. The offset assumes the 1.6 default scale; scaling
#               the internal panel while docked moves it (see docs).
add_z13_monitor_rules() {
    if file_contains "$MONITORS_LUA" 'output = "HDMI-A-1"'; then
        info "Z13 monitor rules already present in monitors.lua."
        return
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would append Z13 monitor rules to $MONITORS_LUA"
        return
    fi

    info "Adding Z13 monitor rules to monitors.lua..."
    cat >> "$MONITORS_LUA" << 'EOF'

-- Z13: internal panel at the origin, external 4K to its right with both bottom
-- edges flush. eDP follows Omarchy's scaling keys through omarchy_monitor_scale;
-- HDMI is pinned to 120 Hz because its EDID prefers 4K@60. The HDMI offset is
-- for the 1.6 default scale — changing the internal scale while docked shifts it.
hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = omarchy_monitor_scale })
hl.monitor({ output = "HDMI-A-1", mode = "3840x2160@120", position = "1600x-728", scale = 1.25 })
EOF
    success "Z13 monitor rules added to monitors.lua."
}

# Undo the retired dock-disable machinery (the helper and the manual-disable
# toggle it wrote) and drop the dead pre-Quattro hyprland.conf. Leaving the
# toggle behind would keep the internal panel off with no external display
# attached; leaving hyprland.conf behind makes edits there look effective when
# the Lua provider ignores the file entirely.
remove_legacy_hyprland_state() {
    local removed=0

    if [[ -e "$Z13_DOCK" ]]; then
        info "Removing retired dock helper..."
        run_cmd rm -f "$Z13_DOCK"
        removed=1
    fi

    if [[ -e "$INTERNAL_DISABLE_FLAG" ]]; then
        info "Clearing stale internal-monitor-disable toggle..."
        run_cmd rm -f "$INTERNAL_DISABLE_FLAG"
        removed=1
    fi

    if [[ -e "$DEAD_HYPRLAND_CONF" ]]; then
        info "Removing dead pre-Quattro hyprland.conf (Lua provider ignores it)..."
        run_cmd rm -f "$DEAD_HYPRLAND_CONF"
        removed=1
    fi

    (( removed )) && success "Retired Hyprland state removed."
    return 0
}

phase4_run() {
    if [[ ! -f "$HYPRLAND_LUA" ]]; then
        warn "Hyprland Lua config not found at $HYPRLAND_LUA — skipping."
        warn "This phase targets Omarchy 4 (Quattro), which reads .lua, not .conf."
        return
    fi

    # Deploy the Z13 Hyprland module (input, keybinds, autostart, window rules).
    info "Installing Z13 Hyprland module..."
    run_cmd mkdir -p "$HYPR_DIR"
    run_cmd cp "$SCRIPT_DIR/templates/hypr/z13.lua" "$Z13_LUA"
    success "Hyprland module installed at $Z13_LUA"

    # The internal panel is no longer disabled on hotplug. Disabling it drove
    # Omarchy's internal-monitor toggle, whose clamshell watcher and modeless
    # recovery loop issue hyprctl reloads that raced the modeset and froze the
    # session on unplug/replug. This also drops the dead pre-Quattro
    # hyprland.conf.
    remove_legacy_hyprland_state

    # Display config goes in Omarchy's monitors.lua: a concrete default scale so
    # the scaling keys work, then the Z13 per-output rules.
    set_monitors_scale_default
    add_z13_monitor_rules

    # Deploy the platform profile change notification script (Fn+F5).
    info "Installing profile notification script..."
    run_cmd mkdir -p "$HOME/.local/bin"
    run_cmd cp "$SCRIPT_DIR/templates/rog-profile-notify.sh" "$NOTIFY_SCRIPT"
    run_cmd chmod +x "$NOTIFY_SCRIPT"
    success "Profile notification script installed."

    # Deploy the iio-hyprland wrapper (auto-rotation). It suppresses a libdbus
    # abort on the binary's exit paths; z13.lua launches it by absolute path.
    info "Installing iio-hyprland wrapper..."
    run_cmd cp "$SCRIPT_DIR/templates/iio-hyprland-wrapper.sh" "$IIO_WRAPPER"
    run_cmd chmod +x "$IIO_WRAPPER"
    success "iio-hyprland wrapper installed at $IIO_WRAPPER"

    # Load the module from the main config.
    if file_contains "$HYPRLAND_LUA" "$Z13_REQUIRE"; then
        info "Z13 module already required from hyprland.lua."
    else
        info "Requiring Z13 module from hyprland.lua..."
        add_z13_require
        success "hyprland.lua updated."
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        info "Reloading Hyprland..."
        hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed — reload manually."
    fi

    success "Hyprland configuration updated."
}
