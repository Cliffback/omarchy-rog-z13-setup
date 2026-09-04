#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-flashgbx-udev.sh — FlashGBX install + cartridge reader permissions
# =============================================================================
# Sets up FlashGBX (Game Boy / GBA cartridge reader/writer tool) and the
# hardware access it needs on Arch-based systems (Omarchy):
#
#   1. Installs FlashGBX from pacman (official repos) or AUR via yay
#   2. Installs udev rules for common cart reader USB-serial adapters:
#        - CH340/CH341  (1a86:7523)  — GBxCart RW, GBFlash, etc.
#        - STM32 CDC    (0483:5740)
#        - Generic CDC  (1209:B010)
#   3. Reloads udev rules
#   4. Warns about brltty (it claims CH340 devices and breaks cart readers)
#   5. Optionally adds the user to the dialout group
#
# Idempotent: safe to re-run.
#
# Usage:
#   ./scripts/setup-flashgbx-udev.sh              # Apply
#   ./scripts/setup-flashgbx-udev.sh --dry-run    # Preview mode
#   ./scripts/setup-flashgbx-udev.sh --help       # Show help
#
# Source: https://github.com/lesserkuma/FlashGBX
# =============================================================================

# ── Constants ──
UDEV_RULES_FILE="/etc/udev/rules.d/50-flashgbx.rules"
UDEV_RULES_CONTENT='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="B010", MODE="0666"'

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Logging ──
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ── Dry-run wrappers ──
DRY_RUN=0
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    "$@"
}
run_sudo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: sudo $*"
        return 0
    fi
    sudo "$@"
}

# ── Prompt (auto-yes in dry-run) ──
ask_yn() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would ask: $* (auto-yes)"
        return 0
    fi
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ── Usage ──
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Install FlashGBX and set up permissions for Game Boy / GBA cartridge
readers/writers (udev rules, brltty conflict check, dialout group).

Options:
  -d, --dry-run   Show what would be done without making changes
  -h, --help      Show this help message
EOF
}

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Pre-checks ──
if [[ $EUID -eq 0 ]]; then
    error "Do not run as root. Sudo is acquired internally when needed."
    exit 1
fi

if ! command -v pacman &> /dev/null; then
    error "pacman not found — this script targets Arch-based systems."
    exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
    info "Running in dry-run mode. No changes will be made."
fi

# ── 1. Install FlashGBX ──
info "Checking FlashGBX installation..."

if pacman -Q flashgbx &> /dev/null; then
    success "FlashGBX already installed ($(pacman -Q flashgbx | awk '{print $2}'))."
else
    if pacman -Si flashgbx &> /dev/null; then
        if ask_yn "Install flashgbx from pacman (official repos)?"; then
            run_sudo pacman -S --needed flashgbx
            success "Installed flashgbx from pacman."
        else
            info "Skipping pacman install."
        fi
    elif command -v yay &> /dev/null; then
        if ask_yn "flashgbx not in official repos — install from AUR via yay?"; then
            run_cmd yay -S --needed flashgbx
            success "Installed flashgbx from AUR."
        else
            info "Skipping AUR install."
        fi
    else
        warn "flashgbx not in official repos and yay not found."
        warn "Install yay first, or use the AppImage from https://github.com/lesserkuma/FlashGBX/releases"
    fi
fi

# ── 2. udev rules ──
info "Checking udev rules..."

if [[ -f "$UDEV_RULES_FILE" ]]; then
    success "udev rules already present at $UDEV_RULES_FILE"
else
    info "Writing $UDEV_RULES_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would write udev rules to $UDEV_RULES_FILE"
    else
        printf '%s\n' "$UDEV_RULES_CONTENT" | sudo tee "$UDEV_RULES_FILE" > /dev/null
        success "Installed udev rules for cart reader USB adapters."
    fi
fi

# ── 3. Reload udev ──
info "Reloading udev rules..."
run_sudo udevadm control --reload-rules
run_sudo udevadm trigger
success "udev rules reloaded."

# ── 4. brltty conflict check ──
info "Checking for brltty (CH340 driver conflict)..."

if pacman -Q brltty &> /dev/null; then
    warn "brltty is installed — it grabs CH340/CH341 devices and blocks"
    warn "cart readers like GBxCart RW (https://github.com/lesserkuma/FlashGBX)."
    if ask_yn "Remove brltty? (pacman -Rns brltty)"; then
        run_sudo pacman -Rns brltty
        success "Removed brltty."
    else
        warn "Keeping brltty — the cart reader may not be detected."
    fi
else
    success "brltty not installed (no conflict)."
fi

# ── 5. dialout group ──
info "Checking group membership..."

DIALOUT_GID="$(getent group dialout | cut -d: -f3 || true)"
if [[ -z "$DIALOUT_GID" ]]; then
    info "No dialout group on this system (Arch default) — udev rules handle access."
elif id -Gn "$USER" | tr ' ' '\n' | grep -qx dialout; then
    success "User already in dialout group."
else
    if ask_yn "Add $USER to the dialout group? (requires logout/reboot)"; then
        run_sudo usermod -aG dialout "$USER"
        success "Added $USER to dialout. Log out and back in (or reboot) for it to apply."
    fi
fi

# ── 6. Verify ──
info "Checking connected devices..."

USB_MATCHES="$(lsusb 2>/dev/null | grep -Ei '1a86:7523|0483:5740|1209:B010' || true)"
if [[ -n "$USB_MATCHES" ]]; then
    info "Detected cart reader hardware:"
    echo "$USB_MATCHES" | sed 's/^/    /'
    if ls -l /dev/ttyUSB* /dev/ttyACM* 2> /dev/null | grep -q 'rw-rw-rw-'; then
        success "Serial device permissions look good (world-writable)."
    else
        warn "Serial device not world-writable yet — unplug/replug the reader"
        warn "or reboot, then check: ls -l /dev/ttyUSB*"
    fi
else
    info "No cart reader currently plugged in (that's fine)."
    info "Plug it in and check: lsusb | grep -Ei '1a86|0483|1209'"
fi

success "FlashGBX setup complete!"
info "Launch FlashGBX and connect your cartridge reader to test."
