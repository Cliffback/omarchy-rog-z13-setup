#!/bin/bash
# Phase 13: Hibernate Wake Fix (optional)
# Prevents spurious wakes during hibernate caused by the AMD GPIO controller
# (AMDI0030) on Ryzen 7000+ / Strix Halo. Adds a kernel parameter via
# limine-entry-tool to ignore interrupt pins 2 and 3.
# See: https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#Ryzen_7000_Series

HIBERNATE_LIMINE_CONF="/etc/limine-entry-tool.d/hibernate-wake-fix.conf"

phase13_check() {
    grep -q "gpiolib_acpi.ignore_interrupt" /proc/cmdline 2>/dev/null
}

phase13_run() {
    info "Installing GPIO interrupt workaround for hibernate wake fix..."
    info "This prevents the AMD GPIO controller (AMDI0030:00) from sending"
    info "spurious interrupts that immediately wake the system during S4."

    if [[ -f "$HIBERNATE_LIMINE_CONF" ]]; then
        info "Limine config already exists: $HIBERNATE_LIMINE_CONF"
    else
        run_sudo_tee "$HIBERNATE_LIMINE_CONF" \
            '# Hibernate Wake Fix - GPIO interrupt workaround for Ryzen 7000+/Strix Halo\n' \
            '# Prevents spurious wakes during S4 hibernate transition\n' \
            '# See: https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#Ryzen_7000_Series\n' \
            'KERNEL_CMDLINE[default]+=" gpiolib_acpi.ignore_interrupt=AMDI0030:00@2,AMDI0030:00@3"\n'
        success "Created $HIBERNATE_LIMINE_CONF"
    fi

    info "Regenerating boot entries with limine-mkinitcpio..."
    run_sudo limine-mkinitcpio
    success "Boot entries regenerated."

    NEEDS_REBOOT=1
    warn "A reboot is required for the kernel parameter to take effect."
}
