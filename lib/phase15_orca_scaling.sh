#!/bin/bash
# Phase 15: Orca Bambu Studio (optional)
# Installs Orca Bambu Studio from AUR and applies a DPI scaling fix.
# Orca's wxWidgets UI is inherently oversized on Wayland.
# Setting GDK_DPI_SCALE=0.8 compensates across all displays.

ORCA_PKG="orca-bambustudio-appimage"
ORCA_BIN="/usr/bin/Orca-BambuStudio"
ORCA_LAUNCHER="$HOME/.local/bin/orca-scaled"
ORCA_DESKTOP="$HOME/.local/share/applications/Orca-BambuStudio.desktop"

phase15_check() {
    is_pkg_installed "$ORCA_PKG" \
        && [[ -f "$ORCA_LAUNCHER" ]] \
        && grep -q 'GDK_DPI_SCALE' "$ORCA_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$ORCA_LAUNCHER" 2>/dev/null \
        && [[ -f "$ORCA_DESKTOP" ]] \
        && grep -q 'orca-scaled' "$ORCA_DESKTOP" 2>/dev/null \
        && grep -q 'x-scheme-handler/bambustudio' "$ORCA_DESKTOP" 2>/dev/null
}

phase15_run() {
    # Install from AUR if not present
    if ! is_pkg_installed "$ORCA_PKG"; then
        local aur_helper=""
        if has_command yay; then
            aur_helper="yay"
        elif has_command paru; then
            aur_helper="paru"
        fi

        if [[ -z "$aur_helper" ]]; then
            warn "No AUR helper (yay/paru) found. Install $ORCA_PKG manually, then re-run."
            return 0
        fi

        info "Installing Orca Bambu Studio from AUR..."
        run_cmd $aur_helper -S --needed "$ORCA_PKG" || {
            warn "Failed to install $ORCA_PKG"
            return 0
        }
    fi

    if [[ ! -f "$ORCA_BIN" ]]; then
        warn "Orca Bambu Studio binary not found at $ORCA_BIN after install — skipping DPI fix."
        return 0
    fi

    info "Applying DPI scaling fix for Orca Bambu Studio..."
    info "Setting GDK_DPI_SCALE=0.8 to compensate for oversized UI"

    mkdir -p "$(dirname "$ORCA_LAUNCHER")" "$(dirname "$ORCA_DESKTOP")"

    # Create launcher script
    run_cmd tee "$ORCA_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# Orca Bambu Studio launcher with DPI-corrected scaling.
# Orca's wxWidgets UI is inherently oversized on Wayland.
# GDK_DPI_SCALE=0.8 compensates across all displays.

export GDK_DPI_SCALE=0.8
export GDK_BACKEND=x11
exec env LD_PRELOAD=/usr/lib/libsharpyuv.so Orca-BambuStudio "$@"
LAUNCHER
    run_cmd chmod +x "$ORCA_LAUNCHER"
    success "Launcher installed at $ORCA_LAUNCHER"

    # Create desktop entry (shadows /usr/share/applications/Orca-BambuStudio.desktop)
    run_cmd tee "$ORCA_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=Orca-BambuStudio
Exec=${ORCA_LAUNCHER}
Icon=OrcaSlicer
Type=Application
PrefersNonDefaultGPU=true
X-KDE-RunOnDiscreteGpu=true
Categories=Utility;
MimeType=model/stl;application/vnd.ms-3mfdocument;application/prs.wavefront-obj;application/x-amf;x-scheme-handler/bambustudio;x-scheme-handler/bambustudioopen;
EOF
    success "Desktop entry created at $ORCA_DESKTOP"

    # Refresh desktop database so app launchers pick up the override
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null

    # Register as default handler for BambuStudio URI schemes (MakerWorld "Open in BambuStudio")
    run_cmd xdg-mime default Orca-BambuStudio.desktop x-scheme-handler/bambustudio
    run_cmd xdg-mime default Orca-BambuStudio.desktop x-scheme-handler/bambustudioopen

    success "Orca Bambu Studio installed and DPI scaling configured."
}
