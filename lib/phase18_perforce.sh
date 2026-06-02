#!/bin/bash
# Phase 18: Perforce (p4 + p4v) (optional)
# Installs the Perforce CLI (p4) and visual client (p4v) from AUR,
# and applies a HiDPI scaling fix for P4V.
#
# P4V's Qt6 UI renders at unscaled resolution on Wayland/HiDPI displays.
# A launcher wrapper reads the current monitor scale and exports
# QT_SCALE_FACTOR so the UI matches other apps across all displays.

P4_PKG="p4"
P4V_PKG="p4v"
P4V_BIN="/usr/bin/p4v"
P4V_LAUNCHER="$HOME/.local/bin/p4v-scaled"
P4V_DESKTOP="$HOME/.local/share/applications/p4v.desktop"

phase18_check() {
    is_pkg_installed "$P4_PKG" \
        && is_pkg_installed "$P4V_PKG" \
        && [[ -f "$P4V_LAUNCHER" ]] \
        && grep -q 'QT_SCALE_FACTOR' "$P4V_LAUNCHER" 2>/dev/null \
        && [[ -f "$P4V_DESKTOP" ]] \
        && grep -q 'p4v-scaled' "$P4V_DESKTOP" 2>/dev/null
}

phase18_run() {
    local aur_helper=""
    if has_command yay; then
        aur_helper="yay"
    elif has_command paru; then
        aur_helper="paru"
    fi

    if [[ -z "$aur_helper" ]]; then
        warn "No AUR helper (yay/paru) found. Install $P4_PKG and $P4V_PKG manually, then re-run."
        return 0
    fi

    # Install p4 CLI if not present
    if ! is_pkg_installed "$P4_PKG"; then
        info "Installing Perforce CLI ($P4_PKG) from AUR..."
        run_cmd $aur_helper -S --needed "$P4_PKG" || {
            warn "Failed to install $P4_PKG"
            return 0
        }
    fi

    # Install p4v GUI if not present
    if ! is_pkg_installed "$P4V_PKG"; then
        info "Installing Perforce Visual Client ($P4V_PKG) from AUR..."
        run_cmd $aur_helper -S --needed "$P4V_PKG" || {
            warn "Failed to install $P4V_PKG"
            return 0
        }
    fi

    if [[ ! -f "$P4V_BIN" ]]; then
        warn "P4V binary not found at $P4V_BIN after install — skipping scaling fix."
        return 0
    fi

    info "Applying HiDPI scaling fix for P4V..."
    info "Formula: QT_SCALE_FACTOR = current monitor scale"

    mkdir -p "$(dirname "$P4V_LAUNCHER")" "$(dirname "$P4V_DESKTOP")"

    # Create launcher script
    run_cmd tee "$P4V_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# P4V launcher with HiDPI scaling fix.
# P4V's Qt6 UI renders at unscaled resolution on Wayland/HiDPI displays.
# Setting QT_SCALE_FACTOR to the current monitor scale fixes this.
#
# Note: If P4V modal dialogs cause the cursor to warp to the dialog
# center when moved outside, add `cursor:no_warps = true` to your
# Hyprland config.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

export QT_SCALE_FACTOR="$SCALE"
exec /usr/bin/p4v "$@"
LAUNCHER
    run_cmd chmod +x "$P4V_LAUNCHER"
    success "Launcher installed at $P4V_LAUNCHER"

    # Create desktop entry (shadows /usr/share/applications/p4v.desktop)
    run_cmd tee "$P4V_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=P4V
Comment=Perforce Visual Client
Exec=${P4V_LAUNCHER} %U
Icon=p4v
Terminal=false
Type=Application
Categories=GNOME;Application;Development;
StartupWMClass=p4v.bin
EOF
    success "Desktop entry created at $P4V_DESKTOP"

    # Refresh desktop database so app launchers pick up the override
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null

    success "Perforce (p4 + p4v) installed and HiDPI scaling configured."
}
