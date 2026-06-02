#!/bin/bash
# =============================================================================
# nvim — Smart wrapper for Unreal Engine ↔ Neovim bidirectional integration
# =============================================================================
# Intercepts nvim calls from UE's NeovimSourceCodeAccess plugin so that:
#   1. Dead sockets (nvim quit) are detected and handled — UE never freezes
#   2. New nvim instances are auto-spawned via xdg-terminal-exec + setsid
#   3. The spawned nvim opens the correct UE project directory
#
# Place this in ~/UnrealEngine/bin/wrappers/ and ensure it's in PATH
# before the real nvim binary. The launcher (ue-5.5.4) and nvim config
# (via jobstart env) both prepend this directory to PATH.
#
# UE calls this wrapper like:
#   nvim --server <socket> --remote <abs_path>
# where <socket> is whatever nvim reported via the NVIM env variable.
#
# Key findings driving this implementation:
#   - serverstart() is broken on nvim v0.12.2 (creates path but no socket)
#   - v:servername uses random paths in /run/user/1000/ — we must handle ANY path
#   - xdg-terminal-exec run with & in UE's process tree gets killed on parent exit
#   - setsid creates a new session, detaching from UE so terminal stays alive
#   - timeout 3 prevents UE from hanging when remote-sending to a dead socket
#     (nvim --remote to a dead socket hangs indefinitely with no built-in timeout)
#   - The wrapper must parse --server /path (space-separated) not just --server=/path
# =============================================================================

DEBUG_LOG="${DEBUG_LOG:-/tmp/nvim-wrapper-debug.log}"
REAL_NVIM="${REAL_NVIM:-/usr/bin/nvim}"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$DEBUG_LOG"
}

# Check if this is a remote call from UE
IS_REMOTE=false
SERVER_SOCKET=""
EXPECT_SERVER=false
EXPECT_REMOTE=false
REMOTE_FILES=()

for arg in "$@"; do
    if [[ "$arg" == "--remote" ]] || [[ "$arg" == "--remote-send" ]]; then
        IS_REMOTE=true
        EXPECT_REMOTE=true
    fi
    if [[ "$EXPECT_SERVER" == "true" ]]; then
        SERVER_SOCKET="$arg"
        EXPECT_SERVER=false
    fi
    if [[ "$arg" == "--server" ]]; then
        EXPECT_SERVER=true
    fi
    if [[ "$arg" == --server=* ]]; then
        SERVER_SOCKET="${arg#--server=}"
    fi
    # Collect file paths from --remote arguments (absolute paths to C++ files)
    if [[ "$EXPECT_REMOTE" == "true" && "$arg" != --* ]]; then
        REMOTE_FILES+=("$arg")
    fi
done

# If not a remote call, just pass through to real nvim
if [[ "$IS_REMOTE" != "true" || -z "$SERVER_SOCKET" ]]; then
    exec "$REAL_NVIM" "$@"
fi

# This is a remote call from UE. Try it first with a timeout.
log "REMOTE call: socket=$SERVER_SOCKET args=$*"

if timeout 3 "$REAL_NVIM" --server "$SERVER_SOCKET" --remote-send "<Esc>" 2>/dev/null; then
    # Socket alive — run the actual remote command
    log "Socket alive, running remote command"
    exec "$REAL_NVIM" "$@"
fi

TIMEOUT_EXIT=$?
log "FAILED/timeout (exit $TIMEOUT_EXIT)"

# Socket is dead or not responding. Respawn nvim.
log "Socket dead or timeout. Respawning nvim..."

PROJECT_DIR=""
PROJECTDIR_FILE=""
PROJECT_NAME=""

# Try to derive project name from the predictable socket pattern
if [[ "$SERVER_SOCKET" == /tmp/ue-nvim-* ]]; then
    PROJECT_NAME=$(basename "$SERVER_SOCKET" .sock | sed 's/^ue-nvim-//')
    PROJECTDIR_FILE="/tmp/ue-nvim-${PROJECT_NAME}.projectdir"
fi

# If no .projectdir found, walk up from file path to find .uproject
if [[ -z "$PROJECTDIR_FILE" || ! -f "$PROJECTDIR_FILE" ]]; then
    if [[ ${#REMOTE_FILES[@]} -gt 0 ]]; then
        FIRST_FILE="${REMOTE_FILES[0]}"
        DIR=$(dirname "$FIRST_FILE")
        while [[ "$DIR" != "/" ]]; do
            if ls "$DIR"/*.uproject &>/dev/null; then
                PROJECT_DIR="$DIR"
                PROJECT_NAME=$(basename "$DIR")
                PROJECTDIR_FILE="/tmp/ue-nvim-${PROJECT_NAME}.projectdir"
                echo "$PROJECT_DIR" > "$PROJECTDIR_FILE"
                log "Discovered project from file path: $PROJECT_DIR"
                break
            fi
            DIR=$(dirname "$DIR")
        done
    fi
fi

# Fallback: if socket is random but a .projectdir exists on disk, use it
if [[ -z "$PROJECTDIR_FILE" || ! -f "$PROJECTDIR_FILE" ]]; then
    CANDIDATE=$(ls /tmp/ue-nvim-*.projectdir 2>/dev/null | head -1)
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" ]]; then
        PROJECTDIR_FILE="$CANDIDATE"
        PROJECT_NAME=$(basename "$CANDIDATE" .projectdir | sed 's/^ue-nvim-//')
        log "Fallback: using existing projectdir: $PROJECTDIR_FILE"
    fi
fi

if [[ -f "$PROJECTDIR_FILE" ]]; then
    PROJECT_DIR=$(cat "$PROJECTDIR_FILE")
    log "Found project dir: $PROJECT_DIR"
else
    PROJECT_DIR="$HOME"
    log "No project dir found, defaulting to HOME"
fi

# Remove stale socket file so new nvim can bind to the same path
rm -f "$SERVER_SOCKET"
log "Cleaned stale socket: $SERVER_SOCKET"

# Spawn a new nvim listening on the SAME socket path UE expects.
# Use setsid to detach from UE's process tree so the terminal survives
# even after UE's exec call returns.
log "Spawning nvim: socket=$SERVER_SOCKET dir=$PROJECT_DIR"
setsid bash -c "
    if command -v hyprctl &>/dev/null; then
        hyprctl dispatch exec \"[workspace current] xdg-terminal-exec $REAL_NVIM --listen $SERVER_SOCKET $PROJECT_DIR\" &>/dev/null
    else
        xdg-terminal-exec $REAL_NVIM --listen '$SERVER_SOCKET' '$PROJECT_DIR' &
    fi
" </dev/null >>"$DEBUG_LOG" 2>&1 &

# Wait for the socket to appear (with timeout)
log "Waiting for socket to appear..."
for i in {1..30}; do
    sleep 0.1
    if [[ -S "$SERVER_SOCKET" ]]; then
        log "Socket ready after ${i}0ms, retrying remote call"
        if "$REAL_NVIM" "$@" 2>/dev/null; then
            log "RETRY SUCCESS"
            exit 0
        fi
        break
    fi
done

log "ERROR: Socket did not appear in time"
exit $TIMEOUT_EXIT
