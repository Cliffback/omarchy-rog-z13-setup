#!/bin/bash
# diagnose-wifi.sh — MT7925 WiFi diagnostic tool for ASUS ROG Flow Z13
# Run this when WiFi is broken after an update to identify the issue.

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
header()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# Track issues found
ISSUES=()
WARNINGS=()

# ── Ask yes/no ───────────────────────────────────────────────────────────
ask_yn() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "$(echo -e "${BOLD}$prompt [y/n]:${NC} ")" answer
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# ── Known problematic kernel versions ────────────────────────────────────
# Add versions here as they're identified as breaking MT7925
KNOWN_BAD_KERNELS=(
    "6.19.0"
    "6.19.1"
    "6.19.2"
    "6.19.3"
    "6.19.4"
    "6.19.5"
    "6.19.6"
)

# ── Check 1: PCIe Device Detection ───────────────────────────────────────
check_pcie_device() {
    header "Check 1: PCIe Device Detection"
    
    local pcie_output
    pcie_output=$(lspci 2>/dev/null | grep -i "MT7925\|MediaTek.*Network" || true)
    
    if [[ -n "$pcie_output" ]]; then
        success "MT7925 WiFi adapter detected on PCIe bus"
        echo "  $pcie_output"
        
        # Get detailed info
        local pcie_addr
        pcie_addr=$(echo "$pcie_output" | awk '{print $1}')
        if [[ -n "$pcie_addr" ]]; then
            local driver_info
            driver_info=$(lspci -k -s "$pcie_addr" 2>/dev/null | grep -E "Kernel driver|Kernel modules" || true)
            if [[ -n "$driver_info" ]]; then
                echo "$driver_info" | while read -r line; do
                    echo "  $line"
                done
            fi
        fi
        return 0
    else
        error "MT7925 WiFi adapter NOT detected on PCIe bus"
        echo "  This could indicate:"
        echo "    - Hardware disabled in BIOS/UEFI"
        echo "    - Physical hardware failure"
        echo "    - PCIe initialization failure"
        ISSUES+=("PCIe device not detected")
        return 1
    fi
}

# ── Check 2: Kernel Module Status ────────────────────────────────────────
check_module_loaded() {
    header "Check 2: Kernel Module Status"
    
    local modules_loaded
    modules_loaded=$(lsmod 2>/dev/null | grep -E "^mt79" || true)
    
    if [[ -n "$modules_loaded" ]]; then
        success "MT7925 kernel modules loaded:"
        echo "$modules_loaded" | while read -r line; do
            echo "  $line"
        done
        
        # Check module info
        if modinfo mt7925e &>/dev/null; then
            local mod_version mod_file
            mod_version=$(modinfo mt7925e 2>/dev/null | grep "^version:" | awk '{print $2}' || echo "N/A")
            mod_file=$(modinfo mt7925e 2>/dev/null | grep "^filename:" | awk '{print $2}' || echo "N/A")
            echo "  Module version: $mod_version"
            echo "  Module file: $mod_file"
        fi
        return 0
    else
        error "MT7925 kernel modules NOT loaded"
        echo "  Expected modules: mt7925e, mt7925_common, mt792x_lib, mt76"
        
        # Check if module exists
        if modinfo mt7925e &>/dev/null; then
            warn "Module exists but is not loaded"
            echo "  The driver may have failed to initialize"
            ISSUES+=("Module exists but not loaded - initialization failure")
        else
            error "Module mt7925e not found in kernel"
            echo "  This kernel may not have MT7925 support"
            ISSUES+=("Module mt7925e not found in kernel")
        fi
        return 1
    fi
}

# ── Check 3: Kernel Messages ─────────────────────────────────────────────
check_kernel_messages() {
    header "Check 3: Kernel Messages (MT7925 driver)"
    
    local dmesg_output
    dmesg_output=$(journalctl -k -b 0 2>/dev/null | grep -i "mt79" | tail -20 || true)
    
    if [[ -z "$dmesg_output" ]]; then
        warn "No MT7925 kernel messages found"
        echo "  Driver may not have attempted to load"
        WARNINGS+=("No kernel messages for MT7925")
        return 1
    fi
    
    echo "Recent kernel messages:"
    echo "$dmesg_output" | while read -r line; do
        # Highlight errors
        if echo "$line" | grep -qiE "error|fail|timeout|unable"; then
            echo -e "  ${RED}$line${NC}"
        elif echo "$line" | grep -qiE "warn"; then
            echo -e "  ${YELLOW}$line${NC}"
        else
            echo "  $line"
        fi
    done
    
    # Check for specific error patterns
    if echo "$dmesg_output" | grep -qi "firmware"; then
        if echo "$dmesg_output" | grep -qiE "failed|error|timeout"; then
            error "Firmware loading issue detected"
            ISSUES+=("Firmware loading failed")
        fi
    fi
    
    if echo "$dmesg_output" | grep -qi "hardware init failed"; then
        error "Hardware initialization failed"
        ISSUES+=("Hardware init failed")
    fi
    
    if echo "$dmesg_output" | grep -qi "patch semaphore"; then
        error "Patch semaphore error (known MT7925 bug)"
        ISSUES+=("Patch semaphore error")
    fi
    
    if echo "$dmesg_output" | grep -qi "ASIC revision"; then
        success "ASIC detected and firmware communicated"
    fi
    
    return 0
}

# ── Check 4: Firmware Files ──────────────────────────────────────────────
check_firmware_files() {
    header "Check 4: Firmware Files"
    
    local fw_dir="/lib/firmware/mediatek/mt7925"
    
    if [[ ! -d "$fw_dir" ]]; then
        error "Firmware directory not found: $fw_dir"
        ISSUES+=("Firmware directory missing")
        return 1
    fi
    
    local fw_files
    fw_files=$(ls -la "$fw_dir" 2>/dev/null || true)
    
    if [[ -z "$fw_files" ]]; then
        error "No firmware files in $fw_dir"
        ISSUES+=("No firmware files found")
        return 1
    fi
    
    success "Firmware files present:"
    echo "$fw_files" | tail -n +2 | while read -r line; do
        echo "  $line"
    done
    
    # Check firmware package version
    local fw_pkg_version
    fw_pkg_version=$(pacman -Q linux-firmware-mediatek 2>/dev/null | awk '{print $2}' || echo "not installed")
    echo "  Package version: linux-firmware-mediatek $fw_pkg_version"
    
    # Check for pending updates
    local fw_update
    fw_update=$(pacman -Qu linux-firmware-mediatek 2>/dev/null || true)
    if [[ -n "$fw_update" ]]; then
        warn "Firmware update available: $fw_update"
        WARNINGS+=("Firmware update pending")
    fi
    
    return 0
}

# ── Check 5: Modprobe Configuration ──────────────────────────────────────
check_modprobe_config() {
    header "Check 5: Modprobe Configuration"
    
    local config_file="/etc/modprobe.d/mt7925e.conf"
    
    if [[ -f "$config_file" ]]; then
        success "MT7925 modprobe config exists:"
        echo "  $(cat "$config_file")"
        
        if grep -q "disable_aspm=1" "$config_file"; then
            success "ASPM disabled (recommended for stability)"
        else
            warn "ASPM not explicitly disabled"
            echo "  Consider adding: options mt7925e disable_aspm=1"
            WARNINGS+=("ASPM not disabled")
        fi
    else
        warn "No MT7925 modprobe config found"
        echo "  Recommended: Create $config_file with:"
        echo "    options mt7925e disable_aspm=1"
        WARNINGS+=("No modprobe config for mt7925e")
    fi
    
    # Check all modprobe configs
    echo ""
    info "All modprobe configurations:"
    for f in /etc/modprobe.d/*.conf; do
        if [[ -f "$f" ]]; then
            echo "  $(basename "$f"): $(cat "$f" | tr '\n' ' ')"
        fi
    done
    
    return 0
}

# ── Check 6: Kernel Version ──────────────────────────────────────────────
check_kernel_version() {
    header "Check 6: Kernel Version"
    
    local kernel_version
    kernel_version=$(uname -r)
    
    info "Current kernel: $kernel_version"
    
    # Extract base version (e.g., "6.19.6" from "6.19.6-2-cachyos")
    local base_version
    base_version=$(echo "$kernel_version" | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+" || echo "$kernel_version")
    
    # Check against known bad versions
    local is_bad=false
    for bad_ver in "${KNOWN_BAD_KERNELS[@]}"; do
        if [[ "$base_version" == "$bad_ver" ]]; then
            is_bad=true
            break
        fi
    done
    
    if $is_bad; then
        error "Kernel $base_version is in the known-problematic list for MT7925"
        echo "  Known issues in this kernel version may affect WiFi"
        echo "  Consider downgrading to kernel 6.18.x or waiting for a fix"
        ISSUES+=("Running known-bad kernel version: $base_version")
    else
        success "Kernel version not in known-bad list"
    fi
    
    # Check installed kernel packages
    info "Installed kernel packages:"
    pacman -Q linux linux-headers linux-cachyos linux-cachyos-headers 2>/dev/null | while read -r line; do
        echo "  $line"
    done
    
    # Check for kernel updates
    local kernel_updates
    kernel_updates=$(pacman -Qu 2>/dev/null | grep -E "^linux" || true)
    if [[ -n "$kernel_updates" ]]; then
        warn "Kernel updates available:"
        echo "$kernel_updates" | while read -r line; do
            echo "  $line"
        done
    fi
    
    return 0
}

# ── Check 7: Network Interface Status ────────────────────────────────────
check_interface_status() {
    header "Check 7: Network Interface Status"
    
    local wlan_interface
    wlan_interface=$(ip link 2>/dev/null | grep -E "wlan|wlp" | head -1 || true)
    
    if [[ -n "$wlan_interface" ]]; then
        success "WiFi interface found:"
        echo "  $wlan_interface"
        
        # Get more details
        local iface_name
        iface_name=$(echo "$wlan_interface" | awk -F': ' '{print $2}' | awk '{print $1}')
        
        if [[ -n "$iface_name" ]]; then
            local iface_status
            iface_status=$(ip addr show "$iface_name" 2>/dev/null || true)
            echo "$iface_status" | while read -r line; do
                echo "  $line"
            done
            
            # Check if interface is UP
            if echo "$wlan_interface" | grep -q "state UP"; then
                success "Interface is UP"
            elif echo "$wlan_interface" | grep -q "state DOWN"; then
                warn "Interface is DOWN"
                WARNINGS+=("WiFi interface is DOWN")
            fi
        fi
    else
        error "No WiFi interface found"
        echo "  Expected interface like wlan0 or wlp*"
        ISSUES+=("No WiFi interface present")
    fi
    
    return 0
}

# ── Check 8: WiFi Service Status ─────────────────────────────────────────
check_wifi_service() {
    header "Check 8: WiFi Service Status"
    
    # Check iwd (used by Omarchy)
    if systemctl is-active iwd &>/dev/null; then
        success "iwd service is running"
    elif systemctl is-enabled iwd &>/dev/null; then
        warn "iwd is enabled but not running"
        WARNINGS+=("iwd not running")
    else
        info "iwd not enabled (may use NetworkManager instead)"
    fi
    
    # Check NetworkManager as alternative
    if systemctl is-active NetworkManager &>/dev/null; then
        success "NetworkManager is running"
    fi
    
    # Check rfkill status
    if command -v rfkill &>/dev/null; then
        local rfkill_output
        rfkill_output=$(rfkill list wifi 2>/dev/null || true)
        if [[ -n "$rfkill_output" ]]; then
            info "rfkill status:"
            echo "$rfkill_output" | while read -r line; do
                if echo "$line" | grep -qi "blocked: yes"; then
                    echo -e "  ${RED}$line${NC}"
                    ISSUES+=("WiFi is rfkill blocked")
                else
                    echo "  $line"
                fi
            done
        fi
    fi
    
    return 0
}

# ── Interactive Fixes ────────────────────────────────────────────────────
offer_fixes() {
    header "Interactive Fixes"
    
    if [[ ${#ISSUES[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
        success "No issues detected - WiFi should be working"
        return 0
    fi
    
    echo ""
    info "Based on the diagnostics, the following fixes may help:"
    echo ""
    
    # Fix 1: Reload module
    if ask_yn "Try reloading the WiFi module?"; then
        info "Unloading mt7925e module..."
        if sudo modprobe -r mt7925e 2>/dev/null; then
            success "Module unloaded"
        else
            warn "Could not unload module (may not be loaded)"
        fi
        
        sleep 1
        
        info "Loading mt7925e module..."
        if sudo modprobe mt7925e 2>/dev/null; then
            success "Module loaded"
            sleep 2
            
            # Check if interface appeared
            if ip link 2>/dev/null | grep -qE "wlan|wlp"; then
                success "WiFi interface appeared!"
            else
                warn "Interface still not present"
            fi
        else
            error "Failed to load module"
        fi
    fi
    
    # Fix 2: Restart iwd
    if systemctl is-enabled iwd &>/dev/null; then
        if ask_yn "Restart iwd service?"; then
            info "Restarting iwd..."
            if sudo systemctl restart iwd; then
                success "iwd restarted"
            else
                error "Failed to restart iwd"
            fi
        fi
    fi
    
    # Fix 3: Unblock rfkill
    if rfkill list wifi 2>/dev/null | grep -qi "blocked: yes"; then
        if ask_yn "Unblock WiFi via rfkill?"; then
            info "Unblocking WiFi..."
            if sudo rfkill unblock wifi; then
                success "WiFi unblocked"
            else
                error "Failed to unblock WiFi"
            fi
        fi
    fi
    
    # Fix 4: Create modprobe config
    if [[ ! -f /etc/modprobe.d/mt7925e.conf ]]; then
        if ask_yn "Create ASPM-disable modprobe config?"; then
            info "Creating /etc/modprobe.d/mt7925e.conf..."
            if echo "options mt7925e disable_aspm=1" | sudo tee /etc/modprobe.d/mt7925e.conf > /dev/null; then
                success "Config created"
                info "Reboot or reload module to apply"
            else
                error "Failed to create config"
            fi
        fi
    fi
    
    # Fix 5: Regenerate initramfs
    if ask_yn "Regenerate initramfs (may fix firmware loading issues)?"; then
        info "Regenerating initramfs with mkinitcpio..."
        if sudo mkinitcpio -P; then
            success "initramfs regenerated"
            info "Reboot to apply changes"
        else
            error "Failed to regenerate initramfs"
        fi
    fi
    
    echo ""
    info "If WiFi is still broken, consider:"
    echo "  1. Boot a previous Limine snapshot with working kernel"
    echo "  2. Downgrade: sudo pacman -U /var/cache/pacman/pkg/linux-cachyos-6.18.9*.pkg.tar.zst"
    echo "  3. Hold kernel: Add 'IgnorePkg = linux-cachyos linux-cachyos-headers' to /etc/pacman.conf"
}

# ── Export Log ───────────────────────────────────────────────────────────
export_log() {
    local log_file="$HOME/wifi-diagnostic-$(date +%Y%m%d-%H%M%S).log"
    
    {
        echo "=== WiFi Diagnostic Report ==="
        echo "Date: $(date)"
        echo "Kernel: $(uname -r)"
        echo "Machine: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'Unknown')"
        echo ""
        echo "=== lspci ==="
        lspci | grep -i network || echo "No network devices"
        echo ""
        echo "=== lsmod (mt79) ==="
        lsmod | grep mt79 || echo "No mt79 modules"
        echo ""
        echo "=== modinfo mt7925e ==="
        modinfo mt7925e 2>&1 || echo "Module not found"
        echo ""
        echo "=== Kernel messages ==="
        journalctl -k -b 0 2>/dev/null | grep -i mt79 || echo "No messages"
        echo ""
        echo "=== Firmware files ==="
        ls -la /lib/firmware/mediatek/mt7925/ 2>&1 || echo "Directory not found"
        echo ""
        echo "=== Modprobe configs ==="
        cat /etc/modprobe.d/*.conf 2>&1 || echo "No configs"
        echo ""
        echo "=== ip link ==="
        ip link
        echo ""
        echo "=== rfkill ==="
        rfkill list 2>&1 || echo "rfkill not available"
        echo ""
        echo "=== Issues Found ==="
        printf '%s\n' "${ISSUES[@]:-None}"
        echo ""
        echo "=== Warnings ==="
        printf '%s\n' "${WARNINGS[@]:-None}"
    } > "$log_file"
    
    success "Log exported to: $log_file"
}

# ── Summary ──────────────────────────────────────────────────────────────
print_summary() {
    header "Summary"
    
    if [[ ${#ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}Issues found (${#ISSUES[@]}):${NC}"
        for issue in "${ISSUES[@]}"; do
            echo -e "  ${RED}*${NC} $issue"
        done
    fi
    
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warnings (${#WARNINGS[@]}):${NC}"
        for warning in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}*${NC} $warning"
        done
    fi
    
    if [[ ${#ISSUES[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
        echo -e "${GREEN}All checks passed - WiFi hardware and driver appear healthy${NC}"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     MT7925 WiFi Diagnostic Tool (ROG Z13)        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Run all checks
    check_pcie_device || true
    check_module_loaded || true
    check_kernel_messages || true
    check_firmware_files || true
    check_modprobe_config || true
    check_kernel_version || true
    check_interface_status || true
    check_wifi_service || true
    
    # Print summary
    print_summary
    
    # Offer interactive fixes if issues found
    if [[ ${#ISSUES[@]} -gt 0 || ${#WARNINGS[@]} -gt 0 ]]; then
        echo ""
        if ask_yn "Would you like to try interactive fixes?"; then
            offer_fixes
        fi
        
        echo ""
        if ask_yn "Export diagnostic log to file?"; then
            export_log
        fi
    fi
    
    echo ""
    info "Diagnostic complete."
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
