#!/bin/bash
# Phase 14: Lychee Slicer (optional)
# Installs Lychee Slicer from AUR and applies a DPI scaling fix.
# Lychee Slicer (Electron 12) renders UI ~1.25x oversized on Wayland.
# A launcher wrapper reads the current monitor scale and applies a 0.8
# correction factor (scale * 0.8) so the UI matches other apps across
# all displays and scaling levels.

LYCHEE_PKG="lycheeslicer"
LYCHEE_BIN="/opt/LycheeSlicer/lycheeslicer"
LYCHEE_LAUNCHER="$HOME/.local/bin/lychee-scaled"
LYCHEE_DESKTOP="$HOME/.local/share/applications/lycheeslicer.desktop"
LYCHEE_MIME_XML="$HOME/.local/share/mime/packages/lychee-slicer.xml"
LYCHEE_MIME_TYPE="application/x-lychee-slicer"
LYCHEE_MIME_ICON_SRC="/usr/share/icons/hicolor/512x512/apps/lycheeslicer.png"
LYCHEE_MIME_ICON_DST="$HOME/.local/share/icons/hicolor/512x512/mimetypes/application-x-lychee-slicer.png"

phase14_check() {
    is_pkg_installed "$LYCHEE_PKG" \
        && [[ -f "$LYCHEE_LAUNCHER" ]] \
        && grep -q 'force-device-scale-factor' "$LYCHEE_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$LYCHEE_LAUNCHER" 2>/dev/null \
        && [[ -f "$LYCHEE_DESKTOP" ]] \
        && grep -q 'lychee-scaled' "$LYCHEE_DESKTOP" 2>/dev/null \
        && [[ -f "$LYCHEE_MIME_XML" ]] \
        && [[ -f "$LYCHEE_MIME_ICON_DST" ]]
}

phase14_run() {
    # Install from AUR if not present
    if ! is_pkg_installed "$LYCHEE_PKG"; then
        local aur_helper=""
        if has_command yay; then
            aur_helper="yay"
        elif has_command paru; then
            aur_helper="paru"
        fi

        if [[ -z "$aur_helper" ]]; then
            warn "No AUR helper (yay/paru) found. Install $LYCHEE_PKG manually, then re-run."
            return 0
        fi

        info "Installing Lychee Slicer from AUR..."
        run_cmd $aur_helper -S --needed "$LYCHEE_PKG" || {
            warn "Failed to install $LYCHEE_PKG"
            return 0
        }
    fi

    if [[ ! -f "$LYCHEE_BIN" ]]; then
        warn "Lychee Slicer binary not found at $LYCHEE_BIN after install — skipping DPI fix."
        return 0
    fi

    info "Applying DPI scaling fix for Lychee Slicer..."
    info "Formula: device_scale_factor = monitor_scale * 0.8"

    mkdir -p "$(dirname "$LYCHEE_LAUNCHER")" "$(dirname "$LYCHEE_DESKTOP")"

    # Create launcher script
    run_cmd tee "$LYCHEE_LAUNCHER" > /dev/null << 'LAUNCHER'
#!/bin/bash
# Lychee Slicer launcher with DPI-corrected scaling.
# Lychee's UI is inherently ~1.25x oversized. Multiplying the monitor
# scale by 0.8 compensates for this across all displays.

SCALE=$(hyprctl monitors -j | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
active = next((m for m in monitors if m.get('focused')), monitors[0])
print(active.get('scale', 1))
")

FACTOR=$(python3 -c "print(round(${SCALE} * 0.8, 3))")

exec /opt/LycheeSlicer/lycheeslicer --no-sandbox --force-device-scale-factor="$FACTOR" "$@"
LAUNCHER
    run_cmd chmod +x "$LYCHEE_LAUNCHER"
    success "Launcher installed at $LYCHEE_LAUNCHER"

    # Create desktop entry (shadows /usr/share/applications/lycheeslicer.desktop)
    run_cmd tee "$LYCHEE_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=LycheeSlicer
Exec=${LYCHEE_LAUNCHER} %U
Terminal=false
Type=Application
Icon=lycheeslicer
StartupWMClass=LycheeSlicer
Comment=Lychee Slicer
MimeType=x-scheme-handler/lycheeslicer;${LYCHEE_MIME_TYPE};
Categories=Utility;
EOF
    success "Desktop entry created at $LYCHEE_DESKTOP"

    # Refresh desktop database so app launchers pick up the override
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    success "Lychee Slicer installed and DPI scaling configured."

    # Register .lys MIME type so file managers recognise Lychee project files
    info "Registering .lys file association..."
    mkdir -p "$(dirname "$LYCHEE_MIME_XML")"
    run_cmd tee "$LYCHEE_MIME_XML" > /dev/null << 'MIMEXML'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-lychee-slicer">
    <comment>Lychee Slicer Project</comment>
    <magic priority="90">
      <match type="string" value='{"version":' offset="16"/>
    </magic>
    <glob pattern="*.lys" weight="80"/>
  </mime-type>
</mime-info>
MIMEXML
    run_cmd update-mime-database "$HOME/.local/share/mime"

    # Copy the app icon as the MIME type icon so .lys files show the Lychee logo
    if [[ -f "$LYCHEE_MIME_ICON_SRC" ]]; then
        local size
        for size in 48 64 128 256 512; do
            local dst_dir="$HOME/.local/share/icons/hicolor/${size}x${size}/mimetypes"
            mkdir -p "$dst_dir"
            if [[ "$size" -eq 512 ]]; then
                run_cmd cp "$LYCHEE_MIME_ICON_SRC" "$dst_dir/application-x-lychee-slicer.png"
            else
                run_cmd magick "$LYCHEE_MIME_ICON_SRC" -resize "${size}x${size}" "$dst_dir/application-x-lychee-slicer.png"
            fi
        done
        run_cmd gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    else
        warn "Lychee app icon not found at $LYCHEE_MIME_ICON_SRC — skipping MIME icon."
    fi

    # Set Lychee Slicer as the default app for .lys files
    run_cmd xdg-mime default lycheeslicer.desktop "$LYCHEE_MIME_TYPE"
    success ".lys files now associated with Lychee Slicer."
}
