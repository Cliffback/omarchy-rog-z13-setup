#!/bin/bash
# Phase 25: Hibernate power-off mode (S5)
# systemd's default HibernateMode=platform ends a hibernate with the firmware's
# ACPI S4 entry. On 2026-11-24 that step hung after the image was written (the
# first S4 after an s2idle suspend in the same kernel): the power button did
# nothing and a hard power-off was needed, after which the image resumed.
# HibernateMode=shutdown powers off through S5, the path every normal shutdown
# takes. systemd-sleep reads sleep.conf on each run, so no reload is needed.
# See docs/hibernation.md "Power-off hang (platform S4)".

HIBERNATE_MODE_SRC="$SCRIPT_DIR/templates/systemd/sleep.conf.d/z13-hibernate-mode.conf"
HIBERNATE_MODE_DEST="/etc/systemd/sleep.conf.d/z13-hibernate-mode.conf"

phase25_check() {
    cmp -s "$HIBERNATE_MODE_SRC" "$HIBERNATE_MODE_DEST"
}

phase25_run() {
    info "Installing $HIBERNATE_MODE_DEST (HibernateMode=shutdown)..."
    run_sudo install -Dm644 "$HIBERNATE_MODE_SRC" "$HIBERNATE_MODE_DEST"
    success "Hibernate now powers off via S5 instead of ACPI S4"

    info "Check: systemd-analyze cat-config systemd/sleep.conf | grep HibernateMode"
    info "After the next hibernate, this must print nothing for that run:"
    info "  journalctl -b -k | grep 'Preparing to enter system sleep state S4'"
}
