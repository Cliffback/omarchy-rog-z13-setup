#!/bin/bash
# repair-deckshift-migration.sh — one-time repair for the DeckShift migration
# bug that removed gamescope-session-steam-git and never restored it.
#
# Background: the pre-0.2.2-z13.1 DeckShift cleanup deleted /usr/bin/steamos-*
# and /usr/bin/jupiter-biosupdate as "old custom session files". Those are
# owned by gamescope-session-steam-git, so the package looked corrupt, got
# queued for remove-and-reinstall, and the reinstall resolved the bare name to
# the CachyOS repo's gamescope-session-cachyos (which Provides/Conflicts the
# same names). That transaction aborted on the conflict with the installed
# gamescope-session-git, leaving no sessions.d/steam — so
# gamescope-session-plus never sets CLIENTCMD and Gaming Mode launches no
# Steam client.
#
# This script restores the package from the local yay cache when available
# (no network/AUR needed) and falls back to the AUR with --aur forced. It then
# removes the retired gaming-mode stack and re-runs verification.
#
# Idempotent: safe to re-run.
#
# Usage:
#   ./scripts/repair-deckshift-migration.sh [--dry-run] [--help]

set -euo pipefail

DRY_RUN=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECKSHIFT="$REPO_DIR/templates/deckshift/deckshift.sh"
PKG="gamescope-session-steam-git"
CACHE_GLOB="$HOME/.cache/yay/$PKG/$PKG-*.pkg.tar.zst"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

usage() {
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage ;;
        *) error "Unknown option: $arg"; usage ;;
    esac
done

[[ $EUID -eq 0 ]] && { error "Do not run as root — sudo is used internally."; exit 1; }
[[ -x "$DECKSHIFT" ]] || { error "DeckShift submodule not checked out at $DECKSHIFT"; exit 1; }

echo ""
echo "================================================================"
echo "  DeckShift migration repair"
echo "================================================================"
echo ""

# --- 1. Restore gamescope-session-steam-git ------------------------------
if pacman -Qi "$PKG" &>/dev/null; then
    success "$PKG is already installed."
else
    warn "$PKG is missing — restoring it."
    cached=""
    for f in $CACHE_GLOB; do
        [[ -f "$f" ]] && cached="$f"
    done

    if [[ -n "$cached" ]]; then
        info "Installing from local cache: $cached"
        run sudo pacman -U --noconfirm "$cached"
    else
        warn "No cached package found — installing from the AUR (--aur forced)."
        warn "The name also exists in the cachyos repo as gamescope-session-cachyos,"
        warn "which conflicts with the installed gamescope-session-git; --aur pins"
        warn "the ChimeraOS package."
        run yay -S --aur --needed --noconfirm "$PKG"
    fi
fi

# --- 2. Verify the functional marker (sessions.d/steam) ------------------
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ -f /usr/share/gamescope-session-plus/sessions.d/steam ]]; then
        success "Steam session client restored (sessions.d/steam)."
    else
        error "sessions.d/steam is STILL missing — Gaming Mode will not launch Steam."
        error "Install manually: yay -S --aur $PKG"
        exit 1
    fi
fi

# --- 3. Remove the retired gaming-mode stack -----------------------------
info "Removing the retired gaming-mode stack (old hook, post-update, stale keybind)..."
run sudo rm -f /etc/pacman.d/hooks/gaming-mode.hook
run sudo rm -f /usr/local/bin/gaming-mode-post-update
run sudo rm -f /usr/local/bin/gaming-session-switch.pre-hotfix
if [[ -f "$HOME/.config/hypr/gaming-mode.conf" ]] \
    && grep -q "switch-to-gaming" "$HOME/.config/hypr/gaming-mode.conf" 2>/dev/null; then
    run rm -f "$HOME/.config/hypr/gaming-mode.conf"
fi

# --- 4. Re-verify --------------------------------------------------------
echo ""
if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would cache sudo and run: $DECKSHIFT --verify"
else
    info "Running DeckShift verification (sudo cached)..."
    sudo -v
    echo ""
    bash "$DECKSHIFT" --verify || true
fi

echo ""
success "Repair complete. Reboot or re-enter Gaming Mode to confirm Steam launches."
echo ""
