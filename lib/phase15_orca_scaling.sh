#!/bin/bash
# Phase 15: Orca Studio (optional)
# Installs Orca Studio from AUR (package orca-bambustudio-appimage) and applies
# a DPI scaling fix. Orca's wxWidgets UI is inherently oversized on Wayland.
# Setting GDK_DPI_SCALE=0.8 compensates across all displays.

ORCA_PKG="orca-bambustudio-appimage"
ORCA_LAUNCHER="$HOME/.local/bin/orca-scaled"
ORCA_DESKTOP="$HOME/.local/share/applications/com.orcaslicer.OrcaStudio.desktop"
# Pre-rename override: the package used to ship /usr/bin/Orca-BambuStudio and
# this desktop ID. Left behind it keeps claiming the model MIME types and the
# bambustudio:// schemes while pointing at a now-missing binary.
ORCA_STALE_DESKTOP="$HOME/.local/share/applications/Orca-BambuStudio.desktop"

# Resolve the binary the installed package actually ships by reading its own
# .desktop Exec= line (upstream renamed Orca-BambuStudio -> orcastudio), with a
# command lookup fallback. Echoes the path/name, or nothing if unresolvable.
phase15_bin() {
    local desktop bin=""
    desktop=$(packaged_desktop "$ORCA_PKG") || true
    if [[ -n "$desktop" ]]; then
        bin=$(desktop_exec_bin "$desktop") || true
    fi
    if [[ -z "$bin" ]]; then
        bin=$(command -v orcastudio 2>/dev/null || command -v Orca-BambuStudio 2>/dev/null) || true
    fi
    printf '%s\n' "$bin"
}

phase15_check() {
    is_pkg_installed "$ORCA_PKG" || return 1

    [[ -f "$ORCA_LAUNCHER" ]] \
        && grep -q 'GDK_DPI_SCALE' "$ORCA_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$ORCA_LAUNCHER" 2>/dev/null || return 1

    [[ -f "$ORCA_DESKTOP" ]] \
        && grep -q 'orca-scaled' "$ORCA_DESKTOP" 2>/dev/null \
        && grep -q '^MimeType=' "$ORCA_DESKTOP" 2>/dev/null \
        && grep -q 'x-scheme-handler/bambustudio' "$ORCA_DESKTOP" 2>/dev/null || return 1

    # The launcher must point at a binary that currently resolves — this is what
    # catches an upstream rename that left the old launcher dangling.
    local bin
    bin=$(phase15_bin)
    [[ -n "$bin" ]] && has_command "$bin" || return 1
    grep -qF "$bin" "$ORCA_LAUNCHER" 2>/dev/null || return 1

    return 0
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

        info "Installing Orca Studio from AUR..."
        run_cmd $aur_helper -S --needed "$ORCA_PKG" || {
            warn "Failed to install $ORCA_PKG"
            return 0
        }
    fi

    local orca_bin orca_src preload=""
    orca_bin=$(phase15_bin)
    orca_src=$(packaged_desktop "$ORCA_PKG") || true

    if [[ -z "$orca_bin" || ! -x "$orca_bin" ]]; then
        warn "Orca Studio binary not found after install — skipping DPI fix."
        return 0
    fi
    if [[ -z "$orca_src" ]]; then
        warn "Orca Studio .desktop not found in package — skipping DPI fix."
        return 0
    fi
    [[ -f /usr/lib/libsharpyuv.so ]] && preload="LD_PRELOAD=/usr/lib/libsharpyuv.so "

    info "Applying DPI scaling fix for Orca Studio..."
    info "Setting GDK_DPI_SCALE=0.8 to compensate for oversized UI"

    mkdir -p "$(dirname "$ORCA_LAUNCHER")"

    # Create launcher script (binary path resolved from the package above)
    run_cmd tee "$ORCA_LAUNCHER" > /dev/null << LAUNCHER
#!/bin/bash
# Orca Studio launcher with DPI-corrected scaling.
# Orca's wxWidgets UI is inherently oversized on Wayland.
# GDK_DPI_SCALE=0.8 compensates across all displays.

export GDK_DPI_SCALE=0.8
export GDK_BACKEND=x11
ORCA_BINARY=${orca_bin}
exec env ${preload}"\$ORCA_BINARY" "\$@"
LAUNCHER
    run_cmd chmod +x "$ORCA_LAUNCHER"
    success "Launcher installed at $ORCA_LAUNCHER"

    # Drop the stale pre-rename override so it stops owning the MIME types
    if [[ -f "$ORCA_STALE_DESKTOP" ]]; then
        run_cmd rm -f "$ORCA_STALE_DESKTOP"
        info "Removed stale Orca-BambuStudio.desktop override"
    fi

    # Shadow the packaged entry, replacing only Exec= (keeps MimeType/Icon in sync)
    if deploy_scaled_desktop "$orca_src" "$ORCA_LAUNCHER" "$ORCA_DESKTOP"; then
        # Make sure Orca stays a fallback handler for the bambustudio:// schemes
        # (the packaged entry does not declare them).
        desktop_ensure_mimetypes "$ORCA_DESKTOP" \
            "x-scheme-handler/bambustudio;x-scheme-handler/bambustudioopen"
        success "Desktop entry created at $ORCA_DESKTOP"
    else
        warn "Could not derive desktop entry from $orca_src"
    fi

    # Register as handler for BambuStudio URI schemes (MakerWorld "Open in
    # BambuStudio"). Phase 16 overrides these when Bambu Studio is installed, so
    # Orca stays the fallback if it is not.
    run_cmd xdg-mime default "$(basename "$ORCA_DESKTOP")" x-scheme-handler/bambustudio
    run_cmd xdg-mime default "$(basename "$ORCA_DESKTOP")" x-scheme-handler/bambustudioopen

    success "Orca Studio installed and DPI scaling configured."
}
