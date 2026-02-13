#!/bin/bash
# Phase 2: asusd Service Fix

ASUSD_SERVICE="/usr/lib/systemd/system/asusd.service"
ASUSD_DROPIN_DIR="/etc/systemd/system/asusd.service.d"
ASUSD_DROPIN="$ASUSD_DROPIN_DIR/install.conf"

phase2_check() {
    [[ -f "$ASUSD_SERVICE" ]] \
        && [[ -f "$ASUSD_DROPIN" ]] \
        && is_service_enabled asusd
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
}
