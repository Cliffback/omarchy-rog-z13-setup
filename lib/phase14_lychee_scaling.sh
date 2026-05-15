#!/bin/bash
# Phase 14: Lychee Slicer DPI Scaling (optional)
# Lychee Slicer (Electron 12) renders UI ~1.25x oversized on Wayland.
# This installs a launcher wrapper that reads the current monitor scale
# and applies a 0.8 correction factor (scale * 0.8) so the UI matches
# other apps across all displays and scaling levels.
# See: docs/lychee-dpi-scaling.md

LYCHEE_BIN="/opt/LycheeSlicer/lycheeslicer"
LYCHEE_LAUNCHER="$HOME/.local/bin/lychee-scaled"
LYCHEE_DESKTOP="$HOME/.local/share/applications/lycheeslicer.desktop"

phase14_check() {
    [[ -f "$LYCHEE_BIN" ]] || return 0  # Lychee not installed, nothing to do
    [[ -f "$LYCHEE_LAUNCHER" ]] \
        && grep -q 'force-device-scale-factor' "$LYCHEE_LAUNCHER" 2>/dev/null \
        && grep -q '0.8' "$LYCHEE_LAUNCHER" 2>/dev/null \
        && [[ -f "$LYCHEE_DESKTOP" ]] \
        && grep -q 'lychee-scaled' "$LYCHEE_DESKTOP" 2>/dev/null
}

phase14_run() {
    if [[ ! -f "$LYCHEE_BIN" ]]; then
        warn "Lychee Slicer not found at $LYCHEE_BIN — skipping."
        return 0
    fi

    info "Installing DPI-corrected launcher for Lychee Slicer..."
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
MimeType=x-scheme-handler/lycheeslicer;
Categories=Utility;
EOF
    success "Desktop entry created at $LYCHEE_DESKTOP"

    # Refresh desktop database so app launchers pick up the override
    run_cmd update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    success "Lychee Slicer DPI scaling configured."
}
