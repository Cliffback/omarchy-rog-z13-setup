#!/bin/bash
# Phase 2: asusd Service Fix

ASUSD_SERVICE="/usr/lib/systemd/system/asusd.service"
ASUSD_DROPIN_DIR="/etc/systemd/system/asusd.service.d"
ASUSD_DROPIN="$ASUSD_DROPIN_DIR/install.conf"

AURA_NKEY="/etc/asusd/aura_18c6.ron"

phase2_check() {
    [[ -f "$ASUSD_SERVICE" ]] \
        && [[ -f "$ASUSD_DROPIN" ]] \
        && is_service_enabled asusd \
        && grep -q 'brightness: High' "$AURA_NKEY" 2>/dev/null
}

phase2_run() {
    if [[ ! -f "$ASUSD_SERVICE" ]]; then
        warn "asusd.service not found — is asusctl installed? Skipping."
        return
    fi

    if [[ ! -f "$ASUSD_DROPIN" ]]; then
        info "Creating systemd drop-in for asusd [Install] section..."
        run_sudo mkdir -p "$ASUSD_DROPIN_DIR"
        run_sudo_tee "$ASUSD_DROPIN" '[Install]\nWantedBy=multi-user.target\n'
        success "Drop-in created."
    fi

    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now asusd
    success "asusd enabled and started."

    # Fix N-KEY device (18c6) overriding keyboard brightness to Off on boot.
    # The Z13 has two aura USB devices (keyboard 1a30 + N-KEY 18c6) that both
    # bind to the same asus::kbd_backlight sysfs node. asusd restores brightness
    # per-device on boot, and the N-KEY defaults to Off, killing the backlight.
    if [[ -f "$AURA_NKEY" ]] && ! grep -q 'brightness: High' "$AURA_NKEY"; then
        info "Fixing N-KEY device brightness (aura_18c6.ron → High)..."
        run_sudo sed -i 's/brightness: \(Off\|Low\|Med\)/brightness: High/' "$AURA_NKEY"
        success "N-KEY brightness set to High — backlight will persist across reboots."
    fi
}
