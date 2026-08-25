#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-affinity-filetypes.sh — Associate Affinity file types on the Linux desktop
# =============================================================================
# Makes the Affinity AppImage (installed via Omarchy's affinity-appimage-bin)
# handle its own file extensions, so double-clicking an .af/.afphoto/.afdesign
# (etc.) file in the file manager opens it in Affinity.
#
# What it does:
#   1. Installs MIME type definitions for all 16 .af* extensions to
#      ~/.local/share/mime/packages/affinity-filetypes.xml
#   2. Installs an "affinity-open" launcher to ~/.local/bin/ that converts
#      Unix paths to Z:\ Windows paths for Wine (and bypasses the omarchy
#      launcher's wait-for-exit loop when Affinity is already running)
#   3. Rewrites ~/.local/share/applications/affinity.desktop with
#      Exec=affinity-open %F and the full MimeType list
#   4. Sets affinity.desktop as the default handler for every .af* type
#
# Idempotent: safe to re-run (e.g. after Omarchy regenerates the desktop file).
#
# Usage:
#   ./scripts/setup-affinity-filetypes.sh              # Apply
#   ./scripts/setup-affinity-filetypes.sh --dry-run    # Preview mode
#   ./scripts/setup-affinity-filetypes.sh --help       # Show help
# =============================================================================

# ── Self-contained constants ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates/affinity"
MIME_PACKAGES_DIR="${HOME}/.local/share/mime/packages"
MIME_XML="${MIME_PACKAGES_DIR}/affinity-filetypes.xml"
BIN_DIR="${HOME}/.local/bin"
OPEN_BIN="${BIN_DIR}/affinity-open"
DESKTOP_DIR="${HOME}/.local/share/applications"
DESKTOP_FILE="${DESKTOP_DIR}/affinity.desktop"
ICON_FILE="${DESKTOP_DIR}/icons/affinity.png"

# All Affinity extensions registered inside the Wine prefix
# (.af .afphoto .afdesign are also auto-created by Wine; defined here too
# so this works on a fresh setup)
MIME_TYPES=(
    application/af
    application/afphoto
    application/afdesign
    application/afpub
    application/aftemplate
    application/afbook
    application/afpackage
    application/afstudio
    application/afassets
    application/afbrushes
    application/affont
    application/afluts
    application/afmacros
    application/afpalette
    application/afshort
    application/afstyles
)

# ── Colors (self-contained) ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ── Dry-run wrapper ──
DRY_RUN=0
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    "$@"
}

# ── Usage ──
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Associate all Affinity file extensions with the Affinity app (Wine AppImage),
so .af/.afphoto/.afdesign/.afpub/... files open in Affinity when double-clicked.

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
if [[ ! -x /usr/bin/affinity ]]; then
    error "Affinity not found at /usr/bin/affinity."
    error "Install it first via: omarchy-menu > Install > Creative > Affinity"
    exit 1
fi

if ! command -v omarchy-launch-affinity &> /dev/null; then
    warn "omarchy-launch-affinity not found — affinity-open will fall back to"
    warn "/usr/bin/affinity (no per-monitor DPI scaling)."
fi

if [[ ! -f "${TEMPLATES_DIR}/affinity-filetypes.xml" ]]; then
    error "Template not found: ${TEMPLATES_DIR}/affinity-filetypes.xml"
    exit 1
fi

if [[ ! -f "${TEMPLATES_DIR}/affinity-open.sh" ]]; then
    error "Template not found: ${TEMPLATES_DIR}/affinity-open.sh"
    exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
    info "Running in dry-run mode. No changes will be made."
fi

# ── 1. MIME type definitions ──
info "Checking Affinity MIME type definitions..."

if [[ -f "$MIME_XML" ]] && cmp -s "${TEMPLATES_DIR}/affinity-filetypes.xml" "$MIME_XML"; then
    success "MIME definitions already up to date."
else
    info "Installing $MIME_XML"
    run_cmd mkdir -p "$MIME_PACKAGES_DIR"
    run_cmd cp "${TEMPLATES_DIR}/affinity-filetypes.xml" "$MIME_XML"
    run_cmd update-mime-database "${HOME}/.local/share/mime"
    success "Installed MIME definitions for ${#MIME_TYPES[@]} Affinity types."
fi

# ── 2. affinity-open launcher ──
info "Checking affinity-open launcher..."

if [[ -f "$OPEN_BIN" ]] && cmp -s "${TEMPLATES_DIR}/affinity-open.sh" "$OPEN_BIN"; then
    success "affinity-open already up to date."
else
    info "Installing $OPEN_BIN"
    run_cmd mkdir -p "$BIN_DIR"
    run_cmd cp "${TEMPLATES_DIR}/affinity-open.sh" "$OPEN_BIN"
    run_cmd chmod +x "$OPEN_BIN"
    success "Installed affinity-open."
fi

# ── 3. Desktop file ──
info "Checking affinity.desktop..."

MIMETYPE_LINE="$(printf '%s;' "${MIME_TYPES[@]}")"
DESKTOP_CONTENT="[Desktop Entry]
Name=Affinity Studio
Exec=${OPEN_BIN} %F
Icon=${ICON_FILE}
Type=Application
Categories=Graphics;
MimeType=${MIMETYPE_LINE}
StartupWMClass=affinity.exe"

if [[ -f "$DESKTOP_FILE" ]] && [[ "$(cat "$DESKTOP_FILE")" == "$DESKTOP_CONTENT" ]]; then
    success "affinity.desktop already up to date."
else
    info "Writing $DESKTOP_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would write desktop file with MimeType=${MIMETYPE_LINE}"
    else
        mkdir -p "$DESKTOP_DIR"
        printf '%s\n' "$DESKTOP_CONTENT" > "$DESKTOP_FILE"
    fi
    success "Updated affinity.desktop (Exec=${OPEN_BIN} %F)."
fi

# ── 4. Default handlers ──
# Write explicit entries to mimeapps.list. Resolving via `xdg-mime query default`
# is not enough — affinity.desktop is currently the only handler for these
# types, so the query "works" without an explicit default. But if Wine's
# winemenubuilder ever recreates wine-extension-*.desktop handlers, the
# default could flip or become ambiguous.
info "Setting default application for Affinity types..."

MIMEAPPS="${HOME}/.config/mimeapps.list"

for mt in "${MIME_TYPES[@]}"; do
    if grep -q "^${mt}=affinity.desktop" "$MIMEAPPS" 2>/dev/null; then
        success "$mt -> affinity.desktop (already set)"
    else
        run_cmd xdg-mime default affinity.desktop "$mt"
        success "$mt -> affinity.desktop"
    fi
done

# ── 5. Refresh desktop database ──
run_cmd update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

success "Affinity file associations complete!"
info "Double-click an .af/.afphoto/.afdesign file to test."
info "Note: re-running Omarchy's Affinity installer regenerates the desktop"
info "file — just re-run this script afterwards to restore the associations."
