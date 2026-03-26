#!/bin/bash
# common.sh — Shared utilities for rog-z13-setup

# Dry-run mode (set by install.sh via --dry-run)
DRY_RUN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Logging helpers
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# Ask yes/no — returns 0 for yes, 1 for no
# In dry-run mode, auto-answers yes so the full plan is shown
ask_yn() {
    local prompt="$1"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${BOLD}$prompt [y/n]:${NC} ${GREEN}(auto-yes, dry-run)${NC}"
        return 0
    fi
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

# Enforce running as normal user
require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script as root. Run as your normal user — sudo is called internally."
        exit 1
    fi
}

# Cache sudo credentials with keepalive (skipped in dry-run mode)
ensure_sudo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] Skipping sudo credential request."
        return 0
    fi
    info "Requesting sudo access..."
    sudo -v || { error "Failed to obtain sudo. Exiting."; exit 1; }
    # Keepalive: refresh sudo timestamp in background
    while true; do sudo -n true; sleep 50; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
}

# Cleanup sudo keepalive on exit
cleanup_sudo() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    fi
}

# Package checks
is_pkg_installed() { pacman -Qi "$1" &>/dev/null; }
is_pkg_explicit()  { pacman -Qi "$1" 2>/dev/null | grep -q "Install Reason.*Explicitly installed"; }

# Service checks
is_service_enabled() { systemctl is-enabled "$1" &>/dev/null; }
is_service_active()  { systemctl is-active "$1" &>/dev/null; }

# File content check (fixed string)
file_contains() {
    local path="$1" pattern="$2"
    [[ -f "$path" ]] && grep -qF "$pattern" "$path"
}

# Command existence check
has_command() { command -v "$1" &>/dev/null; }

# Check if gamescope has cap_sys_nice capability
has_gamescope_caps() {
    local gs_bin
    gs_bin=$(command -v gamescope 2>/dev/null) || return 1
    getcap "$gs_bin" 2>/dev/null | grep -q 'cap_sys_nice'
}

# Check if gaming mode pacman hook is installed
has_gaming_mode_hook() {
    [[ -f /etc/pacman.d/hooks/gaming-mode.hook ]]
}

# Check if HDR session override is installed for ROG Flow Z13
# This override forces HDR10 PQ output to work around deficient panel EDID
has_hdr_session_override() {
    local session_file="$HOME/.config/gamescope-session-plus/sessions.d/steam"
    [[ -f "$session_file" ]] && grep -q "GAMESCOPE_DEBUG_FORCE_HDR10_PQ_OUTPUT" "$session_file" 2>/dev/null
}

# Check if refresh rates are configured for ROG Flow Z13 180Hz panel
has_refresh_rates_configured() {
    local env_file="$HOME/.config/environment.d/gamescope-session-plus.conf"
    [[ -f "$env_file" ]] \
        && grep -q "^CUSTOM_REFRESH_RATES=" "$env_file" 2>/dev/null \
        && grep -q "^STEAM_DISPLAY_REFRESH_LIMITS=" "$env_file" 2>/dev/null
}

# Check if Heroic needs gamescope patch (--ozone-platform=x11)
# Returns 0 if patch is needed, 1 if already patched or Heroic not installed
heroic_needs_patch() {
    local asar_file="/opt/Heroic/resources/app.asar"
    
    # Not installed
    [[ ! -f "$asar_file" ]] && return 1
    
    # Check if npm/asar available
    command -v npm &>/dev/null || return 1
    
    # Quick check: extract just main.js and grep for the patch marker
    local tmp_dir
    tmp_dir=$(mktemp -d -t heroic-check.XXXXXX)
    trap "rm -rf '$tmp_dir'" RETURN
    
    # Try to extract - if asar tool not installed, assume needs patch
    if ! npx --yes asar extract "$asar_file" "$tmp_dir" &>/dev/null; then
        return 0  # Can't check, assume needs patch
    fi
    
    # Check if already patched
    if grep -q 'ozone-platform=x11' "$tmp_dir/build/main/main.js" 2>/dev/null; then
        return 1  # Already patched
    fi
    
    return 0  # Needs patch
}

# ── Dry-run wrapper functions ────────────────────────────────────────────

# Run a command (or log it in dry-run mode)
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    "$@"
}

# Run a sudo command (or log it)
run_sudo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: sudo $*"
        return 0
    fi
    sudo "$@"
}

# Write to a file via sudo tee (or log it)
run_sudo_tee() {
    local file="$1"
    shift
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would write to $file"
        return 0
    fi
    printf '%b' "$@" | sudo tee -a "$file" >/dev/null
}

# Append to a user-owned file (or log it)
run_append() {
    local file="$1"
    shift
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would append to $file"
        return 0
    fi
    "$@" >> "$file"
}
