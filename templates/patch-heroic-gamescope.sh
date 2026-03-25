#!/bin/bash
# ============================================================================
#  Patch Heroic Games Launcher for Gamescope Compatibility
#  
#  Adds --ozone-platform=x11 to Steam shortcut generation so Heroic games
#  launch correctly in gamescope/Steam Gaming Mode.
#
#  Exit codes:
#    0 = Success (patched)
#    1 = Already patched (no changes needed)
#    2 = Heroic not installed
#    3 = npm not available
#    4 = asar tool installation failed
#    5 = Extraction failed
#    6 = Patch failed
#    7 = Repack failed
#    8 = Installation failed
# ============================================================================

ASAR_FILE="/opt/Heroic/resources/app.asar"
BACKUP_FILE="/opt/Heroic/resources/app.asar.backup"
TMP_DIR=""
LOG_FILE="/tmp/heroic-patch.log"

# Logging - outputs to both log file and terminal
log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
    echo "$*"
}

err() {
    echo "[$(date '+%H:%M:%S')] ERROR: $*" >> "$LOG_FILE"
    echo "ERROR: $*" >&2
}

# Cleanup on exit
cleanup() {
    if [[ -n "$TMP_DIR" ]] && [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Global error trap - catch unexpected failures
trap 'err "Script failed unexpectedly at line $LINENO"' ERR

# Initialize log
echo "=== Heroic Gamescope Patch - $(date) ===" > "$LOG_FILE"

# Enable strict mode after traps are set
set -euo pipefail

# --------------------------------------------------------------------------
# Check prerequisites
# --------------------------------------------------------------------------

# Check if Heroic is installed
if [[ ! -f "$ASAR_FILE" ]]; then
    err "Heroic not installed (app.asar not found)"
    exit 2
fi

# Check if npm is available
if ! command -v npm &>/dev/null; then
    err "npm not found - install nodejs and npm packages"
    exit 3
fi

# Ensure @electron/asar is installed globally
if ! npm list -g @electron/asar &>/dev/null; then
    log "Installing @electron/asar tool..."
    if ! npm install -g @electron/asar >> "$LOG_FILE" 2>&1; then
        err "Failed to install @electron/asar"
        exit 4
    fi
fi

# Get asar binary - prefer direct command, fall back to npx
if command -v asar &>/dev/null; then
    ASAR_BIN="asar"
else
    # Use npx to run asar (will use installed version)
    ASAR_BIN="npx --yes asar"
fi

log "Using asar: $ASAR_BIN"

# --------------------------------------------------------------------------
# Extract and check if already patched
# --------------------------------------------------------------------------

TMP_DIR=$(mktemp -d -t heroic-patch.XXXXXX)
log "Extracting app.asar to $TMP_DIR..."

if ! $ASAR_BIN extract "$ASAR_FILE" "$TMP_DIR" >> "$LOG_FILE" 2>&1; then
    err "Failed to extract app.asar"
    exit 5
fi

MAIN_JS="$TMP_DIR/build/main/main.js"

if [[ ! -f "$MAIN_JS" ]]; then
    err "main.js not found in extracted asar"
    exit 5
fi

# Check if already patched
if grep -q 'ozone-platform=x11' "$MAIN_JS"; then
    log "Heroic is already patched for gamescope"
    exit 1
fi

# --------------------------------------------------------------------------
# Apply patch
# --------------------------------------------------------------------------

log "Applying ozone-platform=x11 patch..."

# The shortcut generation code looks like:
#   const S=[];S.push("--no-gui"),M||S.push("--no-sandbox");...
# We need to add S.push("--ozone-platform=x11") before --no-gui

PATCH_PATTERN='const S=\[\];S\.push("--no-gui")'
PATCH_REPLACEMENT='const S=[];S.push("--ozone-platform=x11"),S.push("--no-gui")'

if ! grep -q 'const S=\[\];S\.push("--no-gui")' "$MAIN_JS"; then
    err "Could not find shortcut generation code to patch"
    err "Heroic may have been updated with different code structure"
    exit 6
fi

if ! sed -i "s/$PATCH_PATTERN/$PATCH_REPLACEMENT/g" "$MAIN_JS"; then
    err "sed failed to apply patch"
    exit 6
fi

# Verify patch was applied
if ! grep -q 'ozone-platform=x11' "$MAIN_JS"; then
    err "Patch verification failed - pattern not found after sed"
    exit 6
fi

log "Patch applied successfully"

# --------------------------------------------------------------------------
# Repack asar
# --------------------------------------------------------------------------

PATCHED_ASAR="$TMP_DIR/patched-app.asar"
log "Repacking app.asar..."

# Remove any nested 'extracted' directories that shouldn't be there
[[ -d "$TMP_DIR/extracted" ]] && rm -rf "$TMP_DIR/extracted"

if ! $ASAR_BIN pack "$TMP_DIR" "$PATCHED_ASAR" >> "$LOG_FILE" 2>&1; then
    err "Failed to repack app.asar"
    exit 7
fi

log "Repacked successfully"

# --------------------------------------------------------------------------
# Install patched asar
# --------------------------------------------------------------------------

log "Installing patched app.asar (requires sudo)..."

# Backup original if no backup exists
if [[ ! -f "$BACKUP_FILE" ]]; then
    log "Backing up original to $BACKUP_FILE"
    if ! sudo cp "$ASAR_FILE" "$BACKUP_FILE"; then
        err "Failed to create backup"
        exit 8
    fi
fi

# Install patched version
if ! sudo cp "$PATCHED_ASAR" "$ASAR_FILE"; then
    err "Failed to install patched app.asar"
    exit 8
fi

log "Patched app.asar installed successfully"

# --------------------------------------------------------------------------
# Success
# --------------------------------------------------------------------------

log "=== Heroic patched successfully ==="

cat << 'EOF'

================================================================================
  HEROIC PATCHED SUCCESSFULLY
================================================================================

  Steam shortcuts generated by Heroic will now include:
    --ozone-platform=x11 --no-gui --no-sandbox heroic://launch/...

  This allows Heroic games to display correctly in Gamescope/Gaming Mode.

  IMPORTANT: You need to RE-ADD your games to Steam from Heroic for the
  new shortcut format to take effect. Existing shortcuts won't be updated
  automatically.

  Original backed up to: /opt/Heroic/resources/app.asar.backup

  To revert: sudo cp /opt/Heroic/resources/app.asar.backup /opt/Heroic/resources/app.asar

================================================================================

EOF

exit 0
