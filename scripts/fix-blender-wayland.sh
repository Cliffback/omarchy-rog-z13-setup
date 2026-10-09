#!/usr/bin/env bash
set -euo pipefail

# Fix Blender's tiny/unresizable file dialog on Wayland by forcing XWayland
# and adding a Hyprland centering window rule.

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_DESKTOP="/usr/share/applications/blender.desktop"
USER_DESKTOP_DIR="${HOME}/.local/share/applications"
USER_DESKTOP="${USER_DESKTOP_DIR}/blender.desktop"
HYPR_CONFIG="${HOME}/.config/hypr/hyprland.conf"

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# --- Dry-run wrapper ---
DRY_RUN=0
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    "$@"
}

usage() {
    echo "Usage: $0 [--dry-run] [--help]"
    echo ""
    echo "Fixes Blender's tiny/unresizable file dialog on Wayland by forcing"
    echo "Blender to run via XWayland and centering its windows in Hyprland."
    echo ""
    echo "Options:"
    echo "  -d, --dry-run   Preview changes without applying them"
    echo "  -h, --help      Show this help message"
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# --- Pre-checks ---
if ! command -v blender &> /dev/null; then
    error "Blender is not installed or not in PATH."
    exit 1
fi

if [[ ! -f "$SYSTEM_DESKTOP" ]]; then
    error "System blender.desktop not found at $SYSTEM_DESKTOP"
    exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
    info "Running in dry-run mode. No changes will be made."
fi

# --- 1. Shadow .desktop file ---
info "Checking blender.desktop override..."

if [[ -f "$USER_DESKTOP" ]]; then
    if grep -q "env -u WAYLAND_DISPLAY blender %f" "$USER_DESKTOP"; then
        success "blender.desktop override already exists and is correct."
    else
        warn "blender.desktop override exists but looks different. Re-creating..."
        run_cmd cp "$SYSTEM_DESKTOP" "$USER_DESKTOP"
        run_cmd sed -i 's/^Exec=blender %f/Exec=env -u WAYLAND_DISPLAY blender %f/' "$USER_DESKTOP"
        success "Updated $USER_DESKTOP"
    fi
else
    info "Creating blender.desktop override..."
    run_cmd mkdir -p "$USER_DESKTOP_DIR"
    run_cmd cp "$SYSTEM_DESKTOP" "$USER_DESKTOP"
    run_cmd sed -i 's/^Exec=blender %f/Exec=env -u WAYLAND_DISPLAY blender %f/' "$USER_DESKTOP"
    success "Created $USER_DESKTOP"
fi

# --- 2. Hyprland window rule ---
info "Checking Hyprland window rule..."

if grep -q "windowrule = center 1, match:class blender" "$HYPR_CONFIG"; then
    success "Hyprland window rule for Blender already exists."
else
    info "Adding Hyprland window rule to $HYPR_CONFIG"
    run_cmd bash -c "echo '
# Center Blender windows (file dialogs spawn tiny on native Wayland)
windowrule = center 1, match:class blender' >> \"$HYPR_CONFIG\""
    success "Added Hyprland window rule."
fi

# --- 3. Update desktop database ---
info "Updating desktop database..."
run_cmd update-desktop-database "$USER_DESKTOP_DIR" 2>/dev/null || true

success "Blender Wayland fix applied!"
info "Please restart Blender (and possibly your app launcher) for changes to take effect."
