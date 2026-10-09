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
        && grep -q 'hyprctl monitors' "$BAMBU_LAUNCHER" 2>/dev/null || return 1

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
    info "Deriving GDK scale from the focused Hyprland monitor at launch"

    mkdir -p "$(dirname "$BAMBU_LAUNCHER")"

    # Build the launcher. X11 is forced for smooth rendering, and Hyprland runs
    # with xwayland:force_zero_scaling, so the compositor does not scale the
    # window — the launcher must derive GDK_SCALE/GDK_DPI_SCALE from the focused
    # monitor itself.
    local launcher
    launcher=$(cat << 'LAUNCHER'
#!/bin/bash
# Bambu Studio launcher with DPI-corrected scaling.
# X11 is forced for smooth rendering; with xwayland:force_zero_scaling the
# compositor does not scale us, so derive the GTK scale from the focused monitor.
# Override the target scale with BAMBU_SCALE.

SCALE="${BAMBU_SCALE:-$(hyprctl monitors -j 2>/dev/null | python3 -c '
import json, sys
try:
    monitors = json.load(sys.stdin)
except Exception:
    monitors = []
active = next((m for m in monitors if m.get("focused")), monitors[0] if monitors else {})
print(active.get("scale", 1))
')}"
[[ -n "$SCALE" ]] || SCALE=1
read -r _gdk_scale _gdk_dpi < <(python3 -c "
s = float('$SCALE')
g = max(1, int(s + 0.5))
print(g, s / g)
")
export GDK_SCALE="$_gdk_scale"
export GDK_DPI_SCALE="$_gdk_dpi"
export GDK_BACKEND=x11
BAMBU_BINARY=__BAMBU_BINARY__
exec "$BAMBU_BINARY" "$@"
LAUNCHER
)
    launcher=${launcher//__BAMBU_BINARY__/$BAMBU_BIN}
    printf '%s\n' "$launcher" | run_cmd tee "$BAMBU_LAUNCHER" > /dev/null
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
