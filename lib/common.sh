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
        if ! read -rp "$(echo -e "${BOLD}$prompt [y/n]:${NC} ")" answer; then
            # EOF / non-interactive stdin — don't spin forever on a closed pipe
            echo ""
            warn "No input available — defaulting to no."
            return 1
        fi
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

# Check if the DeckShift pacman hook is installed (re-applies Gaming Mode
# state — gamescope cap, session entry, competing-session disables, Heroic
# patch — after package upgrades).
has_gaming_mode_hook() {
    [[ -f /usr/share/libalpm/hooks/deckshift-gamescope-cap.hook ]]
}

# True once the DeckShift installer has been applied. deckshift-portal-recovery
# is written unconditionally by DeckShift and does not exist in the retired
# Super_shift_S_release.sh + hotfix stack, so it is a reliable migration marker.
# (The pacman hook is prompt-gated, so it can legitimately be absent.)
# A pre-migration install has gamescope + a session entry but no marker, which
# is exactly the state that must NOT be treated as complete.
deckshift_applied() {
    [[ -f /usr/local/bin/deckshift-portal-recovery ]]
}

# Check that the DeckShift submodule is checked out. A plain `git clone`
# without --recursive leaves templates/deckshift empty, so the installer must
# detect that and initialise it rather than failing with a missing-file error.
deckshift_ready() {
    [[ -x "$SCRIPT_DIR/templates/deckshift/deckshift.sh" ]]
}

# Initialise/refresh the DeckShift submodule. Returns 0 on success.
ensure_deckshift_submodule() {
    if deckshift_ready; then
        return 0
    fi
    [[ -d "$SCRIPT_DIR/.git" ]] || return 1
    info "Initialising DeckShift submodule..."
    git -C "$SCRIPT_DIR" submodule update --init --recursive templates/deckshift || return 1
    deckshift_ready
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
