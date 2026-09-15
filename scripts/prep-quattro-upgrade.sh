#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# prep-quattro-upgrade.sh — Back up Z13 customizations before Omarchy Quattro
# =============================================================================
# Omarchy 4 (Quattro) is a one-way rewrite: the desktop shell moves to
# Quickshell (Waybar, Walker, Mako, SwayOSD, hyprlock, hypridle, swaybg are all
# removed), Omarchy internals move from a git checkout to pacman packages, and
# Hyprland configs move from .conf to .lua.
#
# The snapper snapshot taken by the upgrade does NOT protect these files.
# snapper is configured with SUBVOLUME="/", so it snapshots only the @
# subvolume -- not /home (where ~/.config and ~/.local/share/omarchy live), not
# /boot, not /var/log. Rolling back @ restores old binaries while /home stays
# Quattro-era: a mixed, possibly unbootable state.
#
# This script archives everything that would otherwise be lost or invalidated,
# plus reference copies of the system config the upgrade rewrites.
#
# Idempotent: safe to re-run; each run writes a fresh timestamped archive.
#
# Usage:
#   ./scripts/prep-quattro-upgrade.sh              # Archive
#   ./scripts/prep-quattro-upgrade.sh --dry-run    # Preview mode
#   ./scripts/prep-quattro-upgrade.sh --help       # Show help
#
# See docs/omarchy-quattro-upgrade-checklist.md for the full upgrade plan.
# =============================================================================

# ── Config ──
DEST_ROOT="${DEST_ROOT:-$HOME/quattro-prep}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$DEST_ROOT/$STAMP"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# ── Help ──
usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage ;;
        *) error "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Preflight ──
if [[ $EUID -eq 0 ]]; then
    error "Run as your normal user, not root."
    exit 1
fi

if [[ ! -d "$HOME/.local/share/omarchy" ]]; then
    error "Omarchy checkout not found at ~/.local/share/omarchy."
    error "If you already upgraded to Quattro, restore from a previous archive instead."
    exit 1
fi

if [[ -L "$HOME/.local/share/omarchy" ]]; then
    warn "~/.local/share/omarchy is a symlink -- this looks like a post-Quattro system."
    warn "Continuing anyway; the archive will reflect the current state."
fi

info "Quattro prep backup"
info "destination: $DEST"
echo

# ── Helpers ──
# Copy a path into the archive, preserving structure under a label directory.
# Missing paths are reported, not fatal: not every machine has every file.
ARCHIVED=0
SKIPPED=0

archive() {
    local label="$1" src="$2"
    local dest="$DEST/$label"

    if [[ ! -e "$src" && ! -L "$src" ]]; then
        warn "missing, skipped: $src"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would archive: $src -> $dest"
        ARCHIVED=$((ARCHIVED + 1))
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    ARCHIVED=$((ARCHIVED + 1))
}

# Capture a command's output into a file in the archive.
capture() {
    local label="$1"; shift
    local dest="$DEST/$label"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would capture: $* -> $dest"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    "$@" > "$dest" 2>&1 || warn "capture failed (non-fatal): $*"
}

# ── 1. User config that Quattro retires or rewrites ──
info "Archiving user config..."
archive "config/hypr"                    "$HOME/.config/hypr"
archive "config/waybar"                  "$HOME/.config/waybar"
archive "config/walker"                  "$HOME/.config/walker"
archive "config/mako"                    "$HOME/.config/mako"
archive "config/swayosd"                 "$HOME/.config/swayosd"
archive "config/omarchy/hooks"           "$HOME/.config/omarchy/hooks"
archive "config/omarchy/extensions"      "$HOME/.config/omarchy/extensions"
archive "config/omarchy/current"         "$HOME/.config/omarchy/current"
archive "config/omarchy/themed"          "$HOME/.config/omarchy/themed"
archive "config/omarchy/branding"        "$HOME/.config/omarchy/branding"
archive "config/wireplumber"             "$HOME/.config/wireplumber"
archive "config/systemd"                 "$HOME/.config/systemd"

# ── 2. User binaries, including the Z13 scripts ──
# ~/.local/bin can hold large downloaded binaries (standalone tools, not
# customizations). Those are re-downloadable and would bloat the archive, so
# anything over BIN_SIZE_LIMIT is recorded in a manifest instead of copied.
# Quattro does not touch ~/.local/bin except to remove symlinks that point into
# the legacy omarchy checkout, so skipping large binaries is safe.
info "Archiving user binaries..."
BIN_SIZE_LIMIT="${BIN_SIZE_LIMIT:-1M}"
if [[ -d "$HOME/.local/bin" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would archive: $HOME/.local/bin (files under $BIN_SIZE_LIMIT)"
    else
        mkdir -p "$DEST/local/bin"
        : > "$DEST/local/bin/SKIPPED-LARGE-BINARIES.txt"
        while IFS= read -r -d '' f; do
            rel="${f#"$HOME/.local/bin/"}"
            if [[ -f "$f" && ! -L "$f" ]] \
                && [[ $(stat -c %s "$f") -gt $(numfmt --from=iec "$BIN_SIZE_LIMIT") ]]; then
                printf '%s  %s\n' "$(du -h "$f" | cut -f1)" "$rel" \
                    >> "$DEST/local/bin/SKIPPED-LARGE-BINARIES.txt"
                continue
            fi
            mkdir -p "$(dirname "$DEST/local/bin/$rel")"
            cp -a "$f" "$DEST/local/bin/$rel"
        done < <(find "$HOME/.local/bin" -mindepth 1 -print0)
        ARCHIVED=$((ARCHIVED + 1))
        SKIPPED_LARGE=$(wc -l < "$DEST/local/bin/SKIPPED-LARGE-BINARIES.txt")
        if (( SKIPPED_LARGE > 0 )); then
            info "skipped $SKIPPED_LARGE large binaries (recorded in local/bin/SKIPPED-LARGE-BINARIES.txt)"
        fi
    fi
fi

# ── 3. Patched Omarchy internals ──
# The upgrade moves this checkout to a .bak and symlinks it to
# /usr/share/omarchy. Anything patched or untracked here is otherwise lost.
info "Archiving Omarchy checkout (patched internals + untracked scripts)..."
archive "omarchy/bin"                    "$HOME/.local/share/omarchy/bin"
archive "omarchy/migrations"             "$HOME/.local/share/omarchy/migrations"
capture "omarchy/git-status.txt"         git -C "$HOME/.local/share/omarchy" status -sb
capture "omarchy/git-diff.patch"         git -C "$HOME/.local/share/omarchy" diff
capture "omarchy/git-untracked.txt"      git -C "$HOME/.local/share/omarchy" ls-files --others --exclude-standard

# ── 4. System config the upgrade rewrites ──
# These need sudo to read. A single cached credential covers them all.
info "Archiving system config (needs sudo)..."
if sudo -v 2>/dev/null; then
    SUDO_OK=1
else
    SUDO_OK=0
    warn "sudo unavailable -- skipping system config. Re-run with a terminal for these files."
fi

archive_sudo() {
    local label="$1" src="$2"
    local dest="$DEST/$label"

    if [[ $SUDO_OK -eq 0 ]]; then
        return 0
    fi

    if ! sudo test -e "$src" 2>/dev/null; then
        warn "missing, skipped: $src"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would archive: $src -> $dest"
        ARCHIVED=$((ARCHIVED + 1))
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    sudo cp -a "$src" "$dest"
    sudo chown -R "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
    ARCHIVED=$((ARCHIVED + 1))
}

if [[ $SUDO_OK -eq 1 ]]; then
    archive_sudo "system/pacman.conf"                "/etc/pacman.conf"
    archive_sudo "system/default-limine"             "/etc/default/limine"
    archive_sudo "system/limine-entry-tool.d"        "/etc/limine-entry-tool.d"
    archive_sudo "system/mkinitcpio.conf.d"          "/etc/mkinitcpio.conf.d"
    archive_sudo "system/udev/99-power-profile.rules"   "/etc/udev/rules.d/99-power-profile.rules"
    archive_sudo "system/udev/99-wifi-powersave.rules"  "/etc/udev/rules.d/99-wifi-powersave.rules"
    archive_sudo "system/snapper-configs"            "/etc/snapper/configs"
    archive_sudo "system/limine.conf"                "/boot/limine.conf"
fi

# ── 5. Package state, for comparing before/after ──
info "Capturing package state..."
capture "state/pacman-explicit.txt"      pacman -Qqe
capture "state/pacman-all.txt"           pacman -Qq
capture "state/pacman-foreign.txt"       pacman -Qqm
capture "state/pacman-installed-db.txt"  expac -Q '%r %n %v'
capture "state/omarchy-version.txt"      cat "$HOME/.local/share/omarchy/version"
capture "state/uname.txt"                uname -a
capture "state/disk-usage.txt"           df -h /
capture "state/sched-ext-state.txt"      cat /sys/kernel/sched_ext/state

# ── 6. Snapshot + manifest ──
if [[ $DRY_RUN -eq 0 ]]; then
    info "Recording manifest..."
    {
        echo "Quattro prep backup"
        echo "created:  $(date -Is)"
        echo "host:     $(hostname)"
        echo "user:     $USER"
        echo "omarchy:  $(cat "$HOME/.local/share/omarchy/version" 2>/dev/null || echo unknown)"
        echo "kernel:   $(uname -r)"
        echo
        echo "Restore notes:"
        echo "  - config/hypr/*.conf are DEAD after Quattro; port them to .lua."
        echo "  - omarchy/bin holds patched internals; diff against the .bak checkout."
        echo "  - system/udev rules must be reinstalled with updated paths."
        echo "  - see docs/omarchy-quattro-upgrade-checklist.md"
    } > "$DEST/MANIFEST.txt"
fi

# ── Summary ──
echo
echo "=========================================================="
if [[ $DRY_RUN -eq 1 ]]; then
    echo " DRY RUN COMPLETE"
else
    echo " BACKUP COMPLETE"
fi
echo "=========================================================="
echo "archived: $ARCHIVED"
echo "skipped:  $SKIPPED (missing)"
echo "location: $DEST"
if [[ $DRY_RUN -eq 0 ]]; then
    echo "size:     $(du -sh "$DEST" 2>/dev/null | cut -f1)"
fi
echo
echo "Next steps:"
echo "  1. Verify the archive:  ls -R $DEST | less"
echo "  2. Copy it off-machine (or to a separate disk) if possible."
echo "  3. Create a manual snapshot:  omarchy-snapshot create"
echo "  4. Follow docs/omarchy-quattro-upgrade-checklist.md"
echo
if [[ -n "${SUDO_OK:-}" && $SUDO_OK -eq 0 ]]; then
    warn "System config was NOT archived (no sudo). Re-run from a terminal."
fi
