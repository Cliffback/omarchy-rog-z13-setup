#!/bin/bash
# Phase 10: Thunderbolt Dock Fix (optional)
# Prevents the Intel Alpine Ridge Thunderbolt controller from entering D3 sleep,
# working around a buggy ACPI _PS3 method that causes the dock's USB hub
# (and its Ethernet adapter) to fail to enumerate. Also triggers a PCI rescan
# on dock replug to recover from ACPI-corrupted PCI topology teardown.
# See: docs/thunderbolt-dock-d3-fix.md

THUNDERBOLT_UDEV_RULE="/etc/udev/rules.d/99-thunderbolt-no-d3.rules"
THUNDERBOLT_UDEV_TEMPLATE="$SCRIPT_DIR/templates/99-thunderbolt-no-d3.rules"

phase10_check() {
    [[ -f "$THUNDERBOLT_UDEV_RULE" ]] \
        && grep -q 'ATTR{vendor}=="0x8086"' "$THUNDERBOLT_UDEV_RULE" 2>/dev/null \
        && grep -q 'ATTR{device}=="0x15d3"' "$THUNDERBOLT_UDEV_RULE" 2>/dev/null \
        && grep -q 'ATTR{power/control}="on"' "$THUNDERBOLT_UDEV_RULE" 2>/dev/null \
        && grep -q 'SUBSYSTEM=="thunderbolt"' "$THUNDERBOLT_UDEV_RULE" 2>/dev/null \
        && grep -q 'pci/rescan' "$THUNDERBOLT_UDEV_RULE" 2>/dev/null
}

phase10_run() {
    info "Installing udev rules for Thunderbolt dock reliability..."
    info "This prevents ACPI _PS3 timeouts that break dock USB enumeration"
    info "and triggers a PCI rescan on dock replug to recover the PCI topology."

    run_sudo cp "$THUNDERBOLT_UDEV_TEMPLATE" "$THUNDERBOLT_UDEV_RULE"
    success "Udev rules installed at $THUNDERBOLT_UDEV_RULE"

    # Reload udev rules so the change takes effect without a reboot
    info "Reloading udev rules..."
    run_sudo udevadm control --reload-rules
    run_sudo udevadm trigger --action=add --subsystem-match=pci --attr-match=vendor=0x8086 --attr-match=device=0x15d3
    success "Udev rules reloaded and applied."
}
