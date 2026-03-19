#!/bin/bash
# fix-gtk-dark-mode.sh
#
# Fixes GTK/libadwaita apps reverting to light mode after Gamescope sessions.
# The XDG portal Settings interface can get lost when switching compositors,
# causing apps like Nautilus to fall back to light mode.

set -euo pipefail

echo "Re-applying GNOME theme settings..."
omarchy-theme-set-gnome

echo "Restarting XDG portal services..."
systemctl --user restart xdg-desktop-portal-gtk
systemctl --user restart xdg-desktop-portal-hyprland
systemctl --user restart xdg-desktop-portal

# Restart Nautilus if it's running
if pgrep -x nautilus >/dev/null; then
    echo "Restarting Nautilus..."
    nautilus -q 2>/dev/null
    nohup nautilus &>/dev/null &
fi

echo "Done! GTK dark mode should be restored."
