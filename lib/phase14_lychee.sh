#!/bin/bash
# Phase 14: Lychee Slicer (optional)
# Installs Lychee Slicer from AUR and sets up desktop integration: a shadowing
# .desktop entry plus the .lys MIME type and icon. No wrapper launcher is
# deployed — the package's own /usr/bin/lycheeslicer already runs the binary
# with --no-sandbox, and the desktop entry calls it directly.
#
# Do NOT reintroduce --force-device-scale-factor. Earlier versions of this phase
# wrapped the binary in a launcher that forced (monitor_scale * 0.8) to shrink
# Lychee's UI. On Wayland that flag offsets the coordinates of drag-and-drop
# (and context menus, tooltips and <select> popups) by an amount proportional to
# the distance from the window's top-left, so file drops land in the wrong place
# — Chromium bug 40674463. Lychee v8 (CEF / Chromium 150) renders at the
# compositor's fractional scale correctly on its own, so no scale override is
# applied.

LYCHEE_PKG="lycheeslicer"
LYCHEE_BIN="/opt/LycheeSlicer/lycheeslicer"
LYCHEE_DESKTOP="$HOME/.local/share/applications/lycheeslicer.desktop"
LYCHEE_MIME_XML="$HOME/.local/share/mime/packages/lychee-slicer.xml"
LYCHEE_MIME_TYPE="application/x-lychee-slicer"
LYCHEE_MIME_ICON_DST="$HOME/.local/share/icons/hicolor/512x512/mimetypes/application-x-lychee-slicer.png"

# Retired launcher wrappers from earlier versions of this phase.
LYCHEE_LEGACY_LAUNCHERS=(
    "$HOME/.local/bin/lychee-scaled"
    "$HOME/.local/bin/lychee-launcher"
)

phase14_check() {
    local legacy
    is_pkg_installed "$LYCHEE_PKG" || return 1
    [[ -f "$LYCHEE_DESKTOP" ]] || return 1
    grep -q '^Exec=lycheeslicer %U' "$LYCHEE_DESKTOP" 2>/dev/null || return 1
    [[ -f "$LYCHEE_MIME_XML" ]] || return 1
    [[ -f "$LYCHEE_MIME_ICON_DST" ]] || return 1
    for legacy in "${LYCHEE_LEGACY_LAUNCHERS[@]}"; do
        if [[ -e "$legacy" ]]; then
            return 1
        fi
    done
    return 0
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
        warn "Lychee Slicer binary not found at $LYCHEE_BIN after install — skipping desktop integration."
        return 0
    fi

    info "Configuring Lychee Slicer desktop integration..."

    mkdir -p "$(dirname "$LYCHEE_DESKTOP")"

    # Retire launcher wrappers from earlier versions of this phase. The scaled
    # one broke Wayland drag-and-drop (Chromium bug 40674463); the plain one was
    # redundant with the package's /usr/bin/lycheeslicer.
    local legacy
    for legacy in "${LYCHEE_LEGACY_LAUNCHERS[@]}"; do
        if [[ -e "$legacy" ]]; then
            run_cmd rm -f "$legacy"
            info "Removed legacy launcher ($legacy)."
        fi
    done

    # Create desktop entry (shadows /usr/share/applications/lycheeslicer.desktop).
    # Exec calls the package launcher directly; this override exists to advertise
    # the .lys MIME type, which the system entry does not.
    run_cmd tee "$LYCHEE_DESKTOP" > /dev/null << EOF
[Desktop Entry]
Name=LycheeSlicer
Exec=lycheeslicer %U
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
    success "Lychee Slicer installed and desktop integration configured."

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

    # Copy the app icon as the MIME type icon so .lys files show the Lychee logo.
    # Lychee v8 ships only an SVG (hicolor/scalable); older versions shipped a
    # 512x512 PNG. Prefer a raster source, otherwise rasterise the SVG with
    # ImageMagick (RSVG).
    local icon_src=""
    for candidate in \
        /usr/share/icons/hicolor/512x512/apps/lycheeslicer.png \
        /usr/share/icons/hicolor/scalable/apps/lycheeslicer.svg \
        /opt/LycheeSlicer/data/splash/logo-mark.svg; do
        if [[ -f "$candidate" ]]; then
            icon_src="$candidate"
            break
        fi
    done

    if [[ -n "$icon_src" ]]; then
        local size
        for size in 48 64 128 256 512; do
            local dst_dir="$HOME/.local/share/icons/hicolor/${size}x${size}/mimetypes"
            mkdir -p "$dst_dir"
            run_cmd magick -background none -density 384 "$icon_src" \
                -resize "${size}x${size}" "$dst_dir/application-x-lychee-slicer.png"
        done
        run_cmd gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    else
        warn "Lychee app icon not found (hicolor 512 png / scalable svg) — skipping MIME icon."
    fi

    # Set Lychee Slicer as the default app for .lys files
    run_cmd xdg-mime default lycheeslicer.desktop "$LYCHEE_MIME_TYPE"
    success ".lys files now associated with Lychee Slicer."

    # The file-picker centering rule lives in ~/.config/hypr/z13.lua (Phase 4),
    # not here: Omarchy 4 reads .lua, and Phase 4 overwrites that file on every
    # run, so a rule appended from this phase would be wiped.
}
