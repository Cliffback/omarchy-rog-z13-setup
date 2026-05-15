#!/bin/bash
# ============================================================================
#  Hibernate Wake Fix — Prevents spurious wakes during hibernate on AMD Ryzen
#  Specifically for ASUS ROG Flow Z13 (2025) with Strix Halo (Ryzen AI MAX+)
# ============================================================================
set -euo pipefail

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }
success(){ echo "[+] $*"; }

NEEDS_REBOOT=0

echo ""
echo "================================================================"
echo "  HIBERNATE WAKE FIX"
echo "  For AMD Ryzen 7000+ / Strix Halo systems"
echo "================================================================"
echo ""
echo "This script fixes spurious wakes during hibernate caused by:"
echo "  - GPIO controller interrupts (AMDI0030) - Ryzen 7000+ bug"
echo "  - PCIe bridge wake events (GPP0, GPP1, GPP7)"
echo "  - USB4/Thunderbolt controllers (optional)"
echo ""
echo "All fixes are SAFE and will not affect normal boot or device operation."
echo "They only disable wake triggers, not the devices themselves."
echo ""

# --------------------------------------------------------------------------
# FIX 1: GPIO Controller Interrupt Workaround (Kernel Parameter)
# --------------------------------------------------------------------------
# WHY: The AMD GPIO controller (AMDI0030:00) on Ryzen 7000+ series can send
#      spurious interrupts that immediately wake the system during the S4
#      transition. This is a known bug documented in the Arch Wiki.
#      The fix tells the kernel to ignore interrupts from specific GPIO pins.
#
# SAFETY: Very safe. Only ignores specific unused GPIO interrupt pins.
#         Does not affect boot or any device functionality.
# --------------------------------------------------------------------------
echo "================================================================"
echo "  FIX 1: GPIO Controller Interrupt Workaround"
echo "================================================================"
echo ""
echo "PROBLEM: AMD GPIO controller (AMDI0030:00) sends spurious interrupts"
echo "         that wake the system immediately during hibernate."
echo ""
echo "SOLUTION: Add kernel parameter to ignore GPIO pins 2 and 3:"
echo "          gpiolib_acpi.ignore_interrupt=AMDI0030:00@2,AMDI0030:00@3"
echo ""
echo "CURRENT STATUS:"
if grep -q "gpiolib_acpi.ignore_interrupt" /proc/cmdline 2>/dev/null; then
  echo "  Already configured: $(grep -o 'gpiolib_acpi[^ ]*' /proc/cmdline)"
else
  echo "  NOT configured (parameter not in kernel cmdline)"
fi
echo ""

read -rp "Apply FIX 1? (y/n): " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  if grep -q "gpiolib_acpi.ignore_interrupt" /proc/cmdline 2>/dev/null; then
    info "Already configured, skipping."
  else
    CONF_FILE="/etc/limine-entry-tool.d/hibernate-wake-fix.conf"
    if [[ -f "$CONF_FILE" ]]; then
      info "Config file already exists: $CONF_FILE"
    else
      sudo tee "$CONF_FILE" > /dev/null << 'EOF'
# Hibernate Wake Fix - GPIO interrupt workaround for Ryzen 7000+/Strix Halo
# Prevents spurious wakes during S4 hibernate transition
# See: https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#Ryzen_7000_Series
KERNEL_CMDLINE[default]+=" gpiolib_acpi.ignore_interrupt=AMDI0030:00@2,AMDI0030:00@3"
EOF
      success "Created $CONF_FILE"
    fi
    info "Running limine-mkinitcpio to regenerate boot entries..."
    sudo limine-mkinitcpio
    success "Boot entries regenerated."
    NEEDS_REBOOT=1
    warn "REBOOT REQUIRED for this fix to take effect."
  fi
else
  info "Skipped FIX 1"
fi
echo ""

# --------------------------------------------------------------------------
# FIX 2: Disable PCIe Bridge Wakeup (udev rule)
# --------------------------------------------------------------------------
# WHY: PCIe bridges (GPP0, GPP1, GPP7) can trigger spurious wake events,
#      especially on AMD AM5/Strix platforms. This is documented in the
#      Arch Wiki for Gigabyte and MSI AM5 motherboards, and affects similar
#      AMD platforms including ASUS ROG laptops.
#
# SAFETY: Completely safe. Only disables wake capability, not the devices.
#         All PCIe devices continue to work normally.
# --------------------------------------------------------------------------
echo "================================================================"
echo "  FIX 2: Disable PCIe Bridge Wakeup"
echo "================================================================"
echo ""
echo "PROBLEM: PCIe bridges can trigger spurious wake events during hibernate."
echo ""
echo "CURRENT STATUS:"
for dev in GPP0 GPP1 GPP7; do
  line=$(grep "^$dev" /proc/acpi/wakeup 2>/dev/null || echo "$dev  not found")
  echo "  $line"
done
echo ""
echo "SOLUTION: Create udev rule to disable wakeup on PCIe bridges at boot."
echo ""

read -rp "Apply FIX 2? (y/n): " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  RULE_FILE="/etc/udev/rules.d/90-hibernate-pcie-wakeup.rules"
  if [[ -f "$RULE_FILE" ]]; then
    info "udev rule already exists: $RULE_FILE"
  else
    sudo tee "$RULE_FILE" > /dev/null << 'EOF'
# Hibernate Wake Fix - Disable PCIe bridge wakeup
# Prevents spurious wakes from GPP bridges on AMD platforms
# See: https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#GPP_bridge

# GPP0 - PCIe USB4 Bridge (0000:00:01.1)
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:01.1", ATTR{power/wakeup}="disabled"

# GPP1 - PCIe USB4 Bridge (0000:00:01.2)
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:01.2", ATTR{power/wakeup}="disabled"

# GPP7 - PCIe GPP Bridge (0000:00:02.5)
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:02.5", ATTR{power/wakeup}="disabled"
EOF
    success "Created $RULE_FILE"
  fi
  
  # Apply immediately without reboot
  info "Applying changes immediately..."
  for pci in 0000:00:01.1 0000:00:01.2 0000:00:02.5; do
    if [[ -f /sys/bus/pci/devices/$pci/power/wakeup ]]; then
      echo "disabled" | sudo tee /sys/bus/pci/devices/$pci/power/wakeup > /dev/null
      success "Disabled wakeup for $pci"
    fi
  done
  
  echo ""
  echo "NEW STATUS:"
  for dev in GPP0 GPP1 GPP7; do
    line=$(grep "^$dev" /proc/acpi/wakeup 2>/dev/null || echo "$dev  not found")
    echo "  $line"
  done
  success "FIX 2 applied (persistent via udev rule)"
else
  info "Skipped FIX 2"
fi
echo ""

# --------------------------------------------------------------------------
# FIX 3: Disable USB4/Thunderbolt Controller Wakeup (udev rule)
# --------------------------------------------------------------------------
# WHY: USB4/Thunderbolt host routers (NHI0, NHI1) can trigger wake events
#      if a dock or adapter is connected. For hibernate, these should be
#      disabled since you'll use the power button to wake anyway.
#
# SAFETY: Completely safe. Only disables wake capability, not the devices.
#         Thunderbolt/USB4 docks and devices continue to work normally.
# --------------------------------------------------------------------------
echo "================================================================"
echo "  FIX 3: Disable USB4/Thunderbolt Controller Wakeup (Optional)"
echo "================================================================"
echo ""
echo "PROBLEM: USB4/Thunderbolt controllers can trigger wakes if dock connected."
echo ""
echo "CURRENT STATUS:"
for dev in NHI0 NHI1; do
  line=$(grep "^$dev" /proc/acpi/wakeup 2>/dev/null || echo "$dev  not found")
  echo "  $line"
done
echo ""
echo "NOTE: This is optional. Only needed if you have USB-C/Thunderbolt"
echo "      docks or adapters that might trigger spurious wakes."
echo ""

read -rp "Apply FIX 3? (y/n): " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  RULE_FILE="/etc/udev/rules.d/91-hibernate-thunderbolt-wakeup.rules"
  if [[ -f "$RULE_FILE" ]]; then
    info "udev rule already exists: $RULE_FILE"
  else
    sudo tee "$RULE_FILE" > /dev/null << 'EOF'
# Hibernate Wake Fix - Disable USB4/Thunderbolt controller wakeup
# Prevents spurious wakes from Thunderbolt controllers when dock/adapter connected

# NHI0 - USB4 Host Router (0000:c6:00.5)
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:c6:00.5", ATTR{power/wakeup}="disabled"

# NHI1 - USB4 Host Router (0000:c6:00.6)
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:c6:00.6", ATTR{power/wakeup}="disabled"
EOF
    success "Created $RULE_FILE"
  fi
  
  # Apply immediately without reboot
  info "Applying changes immediately..."
  for pci in 0000:c6:00.5 0000:c6:00.6; do
    if [[ -f /sys/bus/pci/devices/$pci/power/wakeup ]]; then
      echo "disabled" | sudo tee /sys/bus/pci/devices/$pci/power/wakeup > /dev/null
      success "Disabled wakeup for $pci"
    fi
  done
  
  echo ""
  echo "NEW STATUS:"
  for dev in NHI0 NHI1; do
    line=$(grep "^$dev" /proc/acpi/wakeup 2>/dev/null || echo "$dev  not found")
    echo "  $line"
  done
  success "FIX 3 applied (persistent via udev rule)"
else
  info "Skipped FIX 3"
fi
echo ""

# --------------------------------------------------------------------------
# SUMMARY
# --------------------------------------------------------------------------
echo "================================================================"
echo "  SUMMARY"
echo "================================================================"
echo ""
echo "Files that may have been created:"
echo ""
[[ -f /etc/limine-entry-tool.d/hibernate-wake-fix.conf ]] && \
  echo "  [x] /etc/limine-entry-tool.d/hibernate-wake-fix.conf (FIX 1)" || \
  echo "  [ ] /etc/limine-entry-tool.d/hibernate-wake-fix.conf (FIX 1)"
[[ -f /etc/udev/rules.d/90-hibernate-pcie-wakeup.rules ]] && \
  echo "  [x] /etc/udev/rules.d/90-hibernate-pcie-wakeup.rules (FIX 2)" || \
  echo "  [ ] /etc/udev/rules.d/90-hibernate-pcie-wakeup.rules (FIX 2)"
[[ -f /etc/udev/rules.d/91-hibernate-thunderbolt-wakeup.rules ]] && \
  echo "  [x] /etc/udev/rules.d/91-hibernate-thunderbolt-wakeup.rules (FIX 3)" || \
  echo "  [ ] /etc/udev/rules.d/91-hibernate-thunderbolt-wakeup.rules (FIX 3)"
echo ""

if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
  echo "*** REBOOT REQUIRED for kernel parameter changes (FIX 1) ***"
  echo ""
fi

echo "TO UNDO ALL FIXES:"
echo "  sudo rm -f /etc/limine-entry-tool.d/hibernate-wake-fix.conf"
echo "  sudo rm -f /etc/udev/rules.d/90-hibernate-pcie-wakeup.rules"
echo "  sudo rm -f /etc/udev/rules.d/91-hibernate-thunderbolt-wakeup.rules"
echo "  sudo limine-mkinitcpio"
echo "  # Then reboot"
echo ""
echo "TO VERIFY after reboot:"
echo "  cat /proc/cmdline | grep gpiolib"
echo "  cat /proc/acpi/wakeup | grep -E 'GPP|NHI'"
echo ""
echo "================================================================"
