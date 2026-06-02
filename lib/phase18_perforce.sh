#!/bin/bash
# Phase 18: Perforce (p4 + p4v + p4admin + p4merge) (optional)
# Installs the Perforce CLI (p4) and visual tools (p4v, p4admin, p4merge)
# from AUR, and applies a HiDPI scaling fix for all Qt6-based GUIs.
#
# P4V, P4Admin and P4Merge's Qt6 UIs render at unscaled resolution on
# Wayland/HiDPI displays. Launcher wrappers read the current monitor scale
# and export QT_SCALE_FACTOR so the UI matches other apps.

P4_PKG="p4"
P4V_PKG="p4v"

P4V_BIN="/usr/bin/p4v"
P4ADMIN_BIN="/usr/bin/p4admin"
P4MERGE_BIN="/usr/bin/p4merge"

P4V_LAUNCHER="$HOME/.local/bin/p4v-scaled"
P4ADMIN_LAUNCHER="$HOME/.local/bin/p4admin-scaled"
P4MERGE_LAUNCHER="$HOME/.local/bin/p4merge-scaled"

P4V_DESKTOP="$HOME/.local/share/applications/p4v.desktop"
P4ADMIN_DESKTOP="$HOME/.local/share/applications/p4admin.desktop"
P4MERGE_DESKTOP="$HOME/.local/share/applications/p4merge.desktop"

phase18_check() {
    is_pkg_installed "$P4_PKG" \
        && is_pkg_installed "$P4V_PKG" \
        && [[ -f "$P4V_LAUNCHER" ]] \
        && grep -q 'QT_SCALE_FACTOR' "$P4V_LAUNCHER" 2>/dev/null \
        && [[ -f "$P4V_DESKTOP" ]] \
        && grep -q 'p4v-scaled' "$P4V_DESKTOP" 2>/dev/null \
        && [[ -f "$P4ADMIN_LAUNCHER" ]] \
        && grep -q 'QT_SCALE_FACTOR' "$P4ADMIN_LAUNCHER" 2>/dev/null \
        && [[ -f "$P4ADMIN_DESKTOP" ]] \
        && grep -q 'p4admin-scaled' "$P4ADMIN_DESKTOP" 2>/dev/null \
        && [[ -f "$P4MERGE_LAUNCHER" ]] \
        && grep -q 'QT_SCALE_FACTOR' "$P4MERGE_LAUNCHER" 2>/dev/null \
        && [[ -f "$P4MERGE_DESKTOP" ]] \
        && grep -q 'p4merge-scaled' "$P4MERGE_DESKTOP" 2>/dev/null
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

    # Install p4v GUI package (contains p4v, p4admin, p4merge) if not present
    if ! is_pkg_installed "$P4V_PKG"; then
        info "Installing Perforce Visual Tools ($P4V_PKG) from AUR..."
        run_cmd $aur_helper -S --needed "$P4V_PKG" || {
            warn "Failed to install $P4V_PKG"
            return 0
        }
    fi

    if [[ ! -f "$P4V_BIN" ]]; then
        warn "P4V binary not found at $P4V_BIN after install — skipping scaling fix."
        return 0
    fi

    info "Applying HiDPI scaling fix for Perforce Qt6 tools..."
    info "Formula: QT_SCALE_FACTOR = current monitor scale"

    mkdir -p "$(dirname "$P4V_LAUNCHER")" "$(dirname "$P4V_DESKTOP")"

    # ── P4V ──
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

    # ── P4Admin ──
    run_cmd tee "$P4ADMIN_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# P4Admin launcher with HiDPI scaling fix.
# P4Admin's Qt6 UI renders at unscaled resolution on Wayland/HiDPI displays.
# Setting QT_SCALE_FACTOR to the current monitor scale fixes this.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

export QT_SCALE_FACTOR="$SCALE"
exec /usr/bin/p4admin "$@"
LAUNCHER
    run_cmd chmod +x "$P4ADMIN_LAUNCHER"
    success "Launcher installed at $P4ADMIN_LAUNCHER"

    run_cmd tee "$P4ADMIN_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=P4Admin
Comment=Perforce Administration Tool
Exec=${P4ADMIN_LAUNCHER} %U
Icon=p4admin
Terminal=false
Type=Application
Categories=GNOME;Application;Development;
StartupWMClass=p4admin.bin
EOF
    success "Desktop entry created at $P4ADMIN_DESKTOP"

    # ── P4Merge ──
    run_cmd tee "$P4MERGE_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# P4Merge launcher with HiDPI scaling fix.
# P4Merge's Qt6 UI renders at unscaled resolution on Wayland/HiDPI displays.
# Setting QT_SCALE_FACTOR to the current monitor scale fixes this.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

export QT_SCALE_FACTOR="$SCALE"
exec /usr/bin/p4merge "$@"
LAUNCHER
    run_cmd chmod +x "$P4MERGE_LAUNCHER"
    success "Launcher installed at $P4MERGE_LAUNCHER"

    run_cmd tee "$P4MERGE_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=P4Merge
Comment=Perforce Merge Tool
Exec=${P4MERGE_LAUNCHER} %U
Icon=p4merge
Terminal=false
Type=Application
Categories=GNOME;Application;Development;
StartupWMClass=p4merge.bin
EOF
    success "Desktop entry created at $P4MERGE_DESKTOP"

    # Refresh desktop database so app launchers pick up the overrides
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null

    success "Perforce (p4 + p4v + p4admin + p4merge) installed and HiDPI scaling configured."
}
