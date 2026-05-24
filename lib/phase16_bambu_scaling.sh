#!/bin/bash
# Phase 16: Bambu Studio AppImage (optional)
# Installs Bambu Studio AppImage from AUR and applies a DPI scaling fix.
# Bambu Studio's wxWidgets UI is inherently oversized on Wayland.
# Setting GDK_DPI_SCALE=0.8 compensates across all displays.

BAMBU_PKG="bambustudio-appimage"
BAMBU_BIN="/usr/bin/bambustudio"
BAMBU_LAUNCHER="$HOME/.local/bin/bambu-scaled"
BAMBU_DESKTOP="$HOME/.local/share/applications/BambuStudio.desktop"

phase16_check() {
    is_pkg_installed "$BAMBU_PKG" \
        && [[ -f "$BAMBU_LAUNCHER" ]] \
        && grep -q 'GDK_DPI_SCALE' "$BAMBU_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$BAMBU_LAUNCHER" 2>/dev/null \
        && [[ -f "$BAMBU_DESKTOP" ]] \
        && grep -q 'bambu-scaled' "$BAMBU_DESKTOP" 2>/dev/null
}

phase16_run() {
    # Install from AUR if not present
    if ! is_pkg_installed "$BAMBU_PKG"; then
        local aur_helper=""
        if has_command yay; then
            aur_helper="yay"
        elif has_command paru; then
            aur_helper="paru"
        fi

        if [[ -z "$aur_helper" ]]; then
            warn "No AUR helper (yay/paru) found. Install $BAMBU_PKG manually, then re-run."
            return 0
        fi

        info "Installing Bambu Studio from AUR..."
        run_cmd $aur_helper -S --needed "$BAMBU_PKG" || {
            warn "Failed to install $BAMBU_PKG"
            return 0
        }
    fi

    if [[ ! -f "$BAMBU_BIN" ]]; then
        warn "Bambu Studio binary not found at $BAMBU_BIN after install — skipping DPI fix."
        return 0
    fi

    info "Applying DPI scaling fix for Bambu Studio..."
    info "Setting GDK_DPI_SCALE=0.8 to compensate for oversized UI"

    mkdir -p "$(dirname "$BAMBU_LAUNCHER")" "$(dirname "$BAMBU_DESKTOP")"

    # Create launcher script
    run_cmd tee "$BAMBU_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# Bambu Studio launcher with DPI-corrected scaling.
# Bambu Studio's wxWidgets UI is inherently oversized on Wayland.
# GDK_DPI_SCALE=0.8 compensates across all displays.

export GDK_DPI_SCALE=0.8
export GDK_BACKEND=x11
exec bambustudio "$@"
LAUNCHER
    run_cmd chmod +x "$BAMBU_LAUNCHER"
    success "Launcher installed at $BAMBU_LAUNCHER"

    # Create desktop entry (shadows /usr/share/applications/BambuStudio.desktop)
    run_cmd tee "$BAMBU_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=BambuStudio
Exec=${BAMBU_LAUNCHER}
Icon=BambuStudio
Type=Application
Categories=Graphics;3DGraphics;
EOF
    success "Desktop entry created at $BAMBU_DESKTOP"

    # Refresh desktop database so app launchers pick up the override
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null

    success "Bambu Studio installed and DPI scaling configured."
}
