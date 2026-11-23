#!/bin/bash
# Phase 13: Hibernate Wake Fix (optional)
# Prevents spurious wakes during hibernate caused by the AMD GPIO controller
# (AMDI0030) on Ryzen 7000+ / Strix Halo. Adds a kernel parameter via
# limine-entry-tool to ignore interrupt pins 2 and 3.
# See: https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#Ryzen_7000_Series
#
# The drop-in itself was always correct. Until 2026-11-23 it had no effect on
# this machine because /etc/default/limine used a plain
# `KERNEL_CMDLINE[default]=`, which discards drop-ins; the guard below catches
# that, and the rebuild is verified against the pending command line.

HIBERNATE_LIMINE_CONF="$LIMINE_DROPIN_DIR/hibernate-wake-fix.conf"
HIBERNATE_GPIO_PARAM="gpiolib_acpi.ignore_interrupt=AMDI0030:00@2,AMDI0030:00@3"

phase13_check() {
    grep -qw -- "$HIBERNATE_GPIO_PARAM" /proc/cmdline 2>/dev/null
}

phase13_run() {
    info "Installing GPIO interrupt workaround for hibernate wake fix..."
    info "This prevents the AMD GPIO controller (AMDI0030:00) from sending"
    info "spurious interrupts that immediately wake the system during S4."

    ensure_limine_dropins_effective || return 1

    if [[ -f "$HIBERNATE_LIMINE_CONF" ]]; then
        info "Limine config already exists: $HIBERNATE_LIMINE_CONF"
    else
        write_limine_dropin "hibernate-wake-fix.conf" \
            "Hibernate Wake Fix - GPIO interrupt workaround for Ryzen 7000+/Strix Halo (spurious S4 wakes)" \
            "$HIBERNATE_GPIO_PARAM"
        success "Created $HIBERNATE_LIMINE_CONF"
    fi

    rebuild_limine_and_verify "$HIBERNATE_GPIO_PARAM" || return 1

    NEEDS_REBOOT=1
    warn "A reboot is required for the kernel parameter to take effect."
}
