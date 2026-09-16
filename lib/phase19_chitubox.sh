#!/bin/bash
# Phase 19: CHITUBOX Basic + ChituManager (optional)
# Installs CHITUBOX Basic from AUR and applies Wayland + DPI scaling fixes.
# CHITUBOX Basic crashes on Hyprland without QT_QPA_PLATFORM=xcb and a safe
# Qt style. ChituManager (remote printer management) is downloaded separately
# from within CHITUBOX Basic; this phase detects it and applies the same fixes.

CHITUBOX_PKG="chitubox-free-bin"
CHITUBOX_BIN="/opt/CHITUBOX_Basic/CHITUBOX_Basic.sh"
CHITUBOX_LAUNCHER="$HOME/.local/bin/chitubox-scaled"
CHITUBOX_DESKTOP="$HOME/.local/share/applications/chitubox-basic.desktop"

CHITU_DIR="$HOME/.local/opt/ChituManager"
CHITU_LAUNCHER="$HOME/.local/bin/chitumanager-scaled"
CHITU_DESKTOP="$HOME/.local/share/applications/chitumanager.desktop"
CHITU_ICON_SRC="$CHITU_DIR/bin/Resources/Icon/icon.png"
CHITU_ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/chitumanager.png"

phase19_check() {
    # Must have CHITUBOX Basic installed and launcher configured
    if ! is_pkg_installed "$CHITUBOX_PKG" || [[ ! -f "$CHITUBOX_BIN" ]]; then
        return 1
    fi

    if [[ ! -f "$CHITUBOX_LAUNCHER" ]] \
        || ! grep -q 'QT_QPA_PLATFORM=xcb' "$CHITUBOX_LAUNCHER" 2>/dev/null \
        || ! grep -q 'QT_STYLE_OVERRIDE=Fusion' "$CHITUBOX_LAUNCHER" 2>/dev/null \
        || ! grep -q 'hyprctl monitors' "$CHITUBOX_LAUNCHER" 2>/dev/null; then
        return 1
    fi

    if [[ ! -f "$CHITUBOX_DESKTOP" ]] \
        || ! grep -q 'chitubox-scaled' "$CHITUBOX_DESKTOP" 2>/dev/null; then
        return 1
    fi

    # If ChituManager is present, it must also be fully configured
    if [[ -d "$CHITU_DIR" ]]; then
        if [[ ! -f "$CHITU_LAUNCHER" ]] \
            || ! grep -q 'QT_QPA_PLATFORM=xcb' "$CHITU_LAUNCHER" 2>/dev/null; then
            return 1
        fi

        if [[ ! -f "$CHITU_DESKTOP" ]] \
            || ! grep -q 'chitumanager-scaled' "$CHITU_DESKTOP" 2>/dev/null; then
            return 1
        fi

        if [[ ! -f "$CHITU_ICON_DST" ]]; then
            return 1
        fi
    fi

    return 0
}

phase19_run() {
    # ── CHITUBOX Basic ──────────────────────────────────────────────────

    if ! is_pkg_installed "$CHITUBOX_PKG"; then
        local aur_helper=""
        if has_command yay; then
            aur_helper="yay"
        elif has_command paru; then
            aur_helper="paru"
        fi

        if [[ -z "$aur_helper" ]]; then
            warn "No AUR helper (yay/paru) found. Install $CHITUBOX_PKG manually, then re-run."
            return 0
        fi

        info "Installing CHITUBOX Basic from AUR..."
        run_cmd $aur_helper -S --needed "$CHITUBOX_PKG" || {
            warn "Failed to install $CHITUBOX_PKG"
            return 0
        }
    fi

    if [[ ! -f "$CHITUBOX_BIN" ]]; then
        warn "CHITUBOX Basic binary not found at $CHITUBOX_BIN after install — skipping."
        return 0
    fi

    info "Applying Wayland + DPI scaling fix for CHITUBOX Basic..."

    mkdir -p "$(dirname "$CHITUBOX_LAUNCHER")" "$(dirname "$CHITUBOX_DESKTOP")"

    # Create launcher script with dynamic Qt scale factor from Hyprland
    run_cmd tee "$CHITUBOX_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# CHITUBOX Basic launcher with Wayland workaround and DPI-corrected scaling.
# CHITUBOX crashes on Hyprland without xcb platform and a safe Qt style.
# Scale factor is read from the focused Hyprland monitor.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

export QT_STYLE_OVERRIDE=Fusion
export QT_QPA_PLATFORM=xcb
export DISABLE_WAYLAND=1
export QT_SCALE_FACTOR="$SCALE"

exec /opt/CHITUBOX_Basic/CHITUBOX_Basic.sh "$@"
LAUNCHER
    run_cmd chmod +x "$CHITUBOX_LAUNCHER"
    success "Launcher installed at $CHITUBOX_LAUNCHER"

    # Shadow the system .desktop entry (fixes broken icon name too)
    run_cmd tee "$CHITUBOX_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=CHITUBOX Basic
GenericName=3D Printer Slicer
Comment=All-in-one SLA/DLP/LCD Slicer
Exec=${CHITUBOX_LAUNCHER} %f
Icon=chitubox-basic
Type=Application
Terminal=false
Categories=Graphics;Utility;
MimeType=model/chitubox;model/ctb;model/cbddlp;model/stl
EOF
    success "Desktop entry created at $CHITUBOX_DESKTOP"

    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    success "CHITUBOX Basic installed and scaling configured."

    # ── ChituManager ────────────────────────────────────────────────────

    if [[ -d "$CHITU_DIR" ]]; then
        info "ChituManager detected — applying Wayland + DPI scaling fix..."

        mkdir -p "$(dirname "$CHITU_LAUNCHER")" "$(dirname "$CHITU_DESKTOP")" "$(dirname "$CHITU_ICON_DST")"

        # Use CHITUBOX Basic icon as fallback (ChituManager icon cache is unreliable
        # due to OpenSSL 3.x incompatibility causing cache rebuild failures)
        if [[ -f "$CHITU_ICON_SRC" ]]; then
            run_cmd cp "$CHITU_ICON_SRC" "$CHITU_ICON_DST" 2>/dev/null || true
            run_cmd gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi

        # Create launcher script with Wayland workaround and post-launch centering
        run_cmd tee "$CHITU_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# ChituManager launcher with Wayland workaround and DPI-corrected scaling.
# Scale factor is read from the focused Hyprland monitor.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

export QT_STYLE_OVERRIDE=Fusion
export QT_QPA_PLATFORM=xcb
export DISABLE_WAYLAND=1
export QT_SCALE_FACTOR="$SCALE"

exec /home/cliffback/.local/opt/ChituManager/ChituManager.sh "$@"
LAUNCHER
        run_cmd chmod +x "$CHITU_LAUNCHER"
        success "Launcher installed at $CHITU_LAUNCHER"

        # Create desktop entry (uses launcher directly)
        run_cmd tee "$CHITU_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=ChituManager
GenericName=3D Printer Manager
Comment=Remote printer management for CHITUBOX
Exec=${CHITU_LAUNCHER}
Icon=chitumanager
Type=Application
Terminal=false
Categories=Graphics;Utility;
EOF
        success "Desktop entry created at $CHITU_DESKTOP"

        # ChituManager is deliberately left tiled: a floating rule crashes it
        # (OpenSSL 3.x incompatibility). The window fits a tile fine at
        # 1200x800 native. The rationale is documented in z13.lua (Phase 4);
        # this phase no longer writes Hyprland config.
        run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
        success "ChituManager configured."
    else
        echo ""
        info "ChituManager not found at $CHITU_DIR"
        info "To install it: launch CHITUBOX Basic, then download ChituManager from within the app."
        info "After installing, re-run ./install.sh and this phase will configure it automatically."
        echo ""
    fi
}
