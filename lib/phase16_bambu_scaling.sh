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
    is_pkg_installed "$BAMBU_PKG" || return 1

    [[ -f "$BAMBU_BIN" ]] || return 1

    [[ -f "$BAMBU_LAUNCHER" ]] \
        && grep -q 'GDK_DPI_SCALE' "$BAMBU_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$BAMBU_LAUNCHER" 2>/dev/null || return 1

    # The override must declare MimeType: without it this entry shadows the
    # packaged one and Bambu Studio vanishes from the file manager's Open-With.
    [[ -f "$BAMBU_DESKTOP" ]] \
        && grep -q 'bambu-scaled' "$BAMBU_DESKTOP" 2>/dev/null \
        && grep -q '^MimeType=.*model/stl' "$BAMBU_DESKTOP" 2>/dev/null || return 1

    return 0
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

    local bambu_src
    bambu_src=$(packaged_desktop "$BAMBU_PKG") || true
    [[ -z "$bambu_src" ]] && bambu_src="/usr/share/applications/BambuStudio.desktop"
    if [[ ! -f "$bambu_src" ]]; then
        warn "Bambu Studio .desktop not found — skipping DPI fix."
        return 0
    fi

    info "Applying DPI scaling fix for Bambu Studio..."
    info "Setting GDK_DPI_SCALE=0.8 to compensate for oversized UI"

    mkdir -p "$(dirname "$BAMBU_LAUNCHER")"

    # Create launcher script
    run_cmd tee "$BAMBU_LAUNCHER" > /dev/null << LAUNCHER
#!/bin/bash
# Bambu Studio launcher with DPI-corrected scaling.
# Bambu Studio's wxWidgets UI is inherently oversized on Wayland.
# GDK_DPI_SCALE=0.8 compensates across all displays.

export GDK_DPI_SCALE=0.8
export GDK_BACKEND=x11
BAMBU_BINARY=${BAMBU_BIN}
exec "\$BAMBU_BINARY" "\$@"
LAUNCHER
    run_cmd chmod +x "$BAMBU_LAUNCHER"
    success "Launcher installed at $BAMBU_LAUNCHER"

    # Shadow the packaged entry, replacing only Exec= — this restores the
    # MimeType line the old hand-written override dropped, so Bambu Studio
    # comes back into the file manager's Open-With list.
    if deploy_scaled_desktop "$bambu_src" "$BAMBU_LAUNCHER" "$BAMBU_DESKTOP"; then
        success "Desktop entry created at $BAMBU_DESKTOP"
    else
        warn "Could not derive desktop entry from $bambu_src"
    fi

    # Bambu Studio is the default handler for 3D model files and bambustudio://
    # URIs (Orca Studio remains available as an Open-With alternative).
    local mime
    for mime in model/stl model/3mf application/vnd.ms-3mfdocument \
                application/prs.wavefront-obj application/x-amf \
                x-scheme-handler/bambustudio x-scheme-handler/bambustudioopen; do
        run_cmd xdg-mime default "$(basename "$BAMBU_DESKTOP")" "$mime"
    done

    success "Bambu Studio installed and DPI scaling configured."
}
