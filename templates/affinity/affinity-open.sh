#!/usr/bin/env bash
set -euo pipefail

# affinity-open — Open Affinity files (.af, .afphoto, .afdesign, ...) from the
# Linux desktop. Deployed to ~/.local/bin/affinity-open by
# scripts/setup-affinity-filetypes.sh
#
# - Converts Unix file paths to Windows Z:\ paths for Wine
#   (the ~/.AffinityLinux-Appimage prefix maps z: -> /)
# - Uses omarchy-launch-affinity (per-monitor DPI scaling) when Affinity is
#   not already running
# - Calls /usr/bin/affinity directly when Affinity IS running, because the
#   omarchy wrapper waits for the running instance to exit before launching —
#   which would otherwise block the file open until you quit Affinity

args=()
for arg in "$@"; do
    if [[ -e $arg ]]; then
        abs="$(realpath "$arg")"
        args+=("Z:${abs//\//\\}")
    else
        args+=("$arg")
    fi
done

if pgrep -f "Affinity.exe" >/dev/null 2>&1; then
    exec /usr/bin/affinity "${args[@]}"
else
    exec omarchy-launch-affinity "${args[@]}"
fi
