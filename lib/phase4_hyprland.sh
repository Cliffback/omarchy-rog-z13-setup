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

# Omarchy's clamshell helper re-applies the scale it reads from monitors.lua on
# every hotplug. With a literal number there it would clobber the 2.0 scale set
# in z13.lua, so the catch-all is left on "auto" for the compositor to resolve.
monitors_scale_defers() {
    [[ -f "$MONITORS_LUA" ]] \
        && grep -q '^local omarchy_monitor_scale = "auto"$' "$MONITORS_LUA"
}

phase4_check() {
    [[ -f "$Z13_LUA" ]] \
        && [[ -x "$NOTIFY_SCRIPT" ]] \
        && [[ -x "$IIO_WRAPPER" ]] \
        && [[ ! -e "$Z13_DOCK" ]] \
        && [[ ! -e "$INTERNAL_DISABLE_FLAG" ]] \
        && [[ ! -e "$DEAD_HYPRLAND_CONF" ]] \
        && monitors_scale_defers \
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

# Leave the monitor catch-all scale to the compositor, so Omarchy's clamshell
# helper defers to the per-output scale in z13.lua instead of re-applying the
# old 1.25 to the internal panel. GDK_SCALE is deliberately left alone: it is
# global and would also scale XWayland apps on the 1.25 external display.
set_monitors_scale_auto() {
    if [[ ! -f "$MONITORS_LUA" ]]; then
        warn "Monitor config not found at $MONITORS_LUA — skipping scale fix."
        return
    fi

    if monitors_scale_defers; then
        info "Monitor catch-all scale already defers to the compositor."
        return
    fi

    if grep -q '^local omarchy_monitor_scale = ' "$MONITORS_LUA"; then
        info "Setting monitor catch-all scale to auto..."
        run_cmd sed -i -E \
            's|^local omarchy_monitor_scale = .*|local omarchy_monitor_scale = "auto"|' \
            "$MONITORS_LUA"
        success "Monitor catch-all scale now defers to the compositor."
    else
        warn "No omarchy_monitor_scale line in $MONITORS_LUA — leaving it alone."
    fi
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

    # Deploy the Z13 Hyprland module (monitors, input, keybinds, autostart,
    # window rules).
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

    # Keep Omarchy's clamshell helper from clobbering the 2.0 internal scale.
    set_monitors_scale_auto

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
