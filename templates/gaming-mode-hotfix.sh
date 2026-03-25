#!/bin/bash
# ============================================================================
#  Gaming Mode Hotfix — run this BEFORE rebooting after an Omarchy update
#  Fixes the "returns to KDE Plasma instead of Hyprland" bug
# ============================================================================
set -euo pipefail

info(){ echo "[*] $*"; }
err(){ echo "[!] $*" >&2; }

echo ""
echo "================================================================"
echo "  GAMING MODE HOTFIX"
echo "================================================================"
echo ""

# --------------------------------------------------------------------------
# FIX 1: Disable plasma.desktop so SDDM can never fall back to it
# --------------------------------------------------------------------------
# WHY: SDDM autologin tries your configured session. If anything goes wrong
#       (session switch fails silently, session name doesn't match), SDDM
#       shows its greeter with all available sessions. plasma.desktop is
#       sitting there as an option, and if Relogin=true kicks in with a
#       stale session, SDDM can auto-pick Plasma as a fallback.
#       By disabling it, the ONLY sessions available are Hyprland and
#       Gamescope — so even failures land somewhere useful.
# --------------------------------------------------------------------------
info "FIX 1: Disabling competing session desktop files..."
for unwanted in plasma.desktop gnome.desktop gnome-wayland.desktop kde-plasma.desktop; do
  path="/usr/share/wayland-sessions/$unwanted"
  if [[ -f "$path" ]]; then
    sudo mv "$path" "${path}.disabled"
    info "  Disabled: $unwanted"
  fi
done
echo ""

# --------------------------------------------------------------------------
# FIX 2: Fix switch-to-desktop using restart instead of stop+start
# --------------------------------------------------------------------------
# WHY: The sudoers file only allows:
#         %video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sddm
#       But switch-to-desktop runs:
#         sudo -n systemctl stop sddm    ← NOT in sudoers, fails silently
#         sudo -n systemctl start sddm   ← NOT in sudoers, fails silently
#       Sudoers matches exact command strings. "stop" ≠ "restart".
#       Both commands fail silently (2>/dev/null || true), so the return
#       path is broken without any error message. SDDM never properly
#       restarts and you end up at whatever session SDDM guesses.
#
# ALSO: The unmask command MUST use --runtime flag to match how switch-to-gaming
#       masks the targets. Without --runtime, unmask looks in /etc/systemd/system/
#       but the runtime masks are in /run/systemd/system/, so hibernation stays broken.
# --------------------------------------------------------------------------
info "FIX 2: Patching switch-to-desktop (restart + --runtime unmask)..."
SWITCH_DESKTOP="/usr/local/bin/switch-to-desktop"
if [[ -f "$SWITCH_DESKTOP" ]]; then
  sudo cp "$SWITCH_DESKTOP" "${SWITCH_DESKTOP}.pre-hotfix"
  info "  Backed up to: ${SWITCH_DESKTOP}.pre-hotfix"
  sudo tee "$SWITCH_DESKTOP" > /dev/null << 'SWITCH_DESKTOP_SCRIPT'
#!/bin/bash
if [[ ! -f /tmp/.gaming-session-active ]]; then
  exit 0
fi
rm -f /tmp/.gaming-session-active

# FIX: Use --runtime to unmask from /run/systemd/system/ where switch-to-gaming masks them
sudo -n systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true

# Re-enable Bluetooth
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true

timeout 5 steam -shutdown 2>/dev/null || true
sleep 1

pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true

for _ in {1..6}; do
  pgrep -x gamescope >/dev/null 2>&1 || break
  sleep 0.5
done

if pgrep -x gamescope >/dev/null 2>&1; then
  pkill -9 gamescope 2>/dev/null || true
  pkill -9 -f gamescope-session 2>/dev/null || true
fi

sleep 2

sudo -n chvt 2 2>/dev/null || true
sleep 0.5
# FIX: Use "restart" which IS allowed by sudoers, not "stop"+"start" which are NOT
sudo -n systemctl restart sddm &
disown
exit 0
SWITCH_DESKTOP_SCRIPT
  sudo chmod +x "$SWITCH_DESKTOP"
  info "  Patched: $SWITCH_DESKTOP"
else
  err "  Not found: $SWITCH_DESKTOP"
fi
echo ""

# --------------------------------------------------------------------------
# FIX 3: Add stop/start sddm and --runtime unmask to sudoers
# --------------------------------------------------------------------------
# WHY: Belt and suspenders. Even though we now use "restart" in the scripts,
#       adding stop/start to sudoers means if any other code path (like a
#       future update to os-session-select or a manual debug session) tries
#       stop/start, it won't silently fail.
#
# ALSO: The unmask --runtime command needs to be in sudoers for the hibernation
#       fix to work. Without it, the unmask command fails silently.
# --------------------------------------------------------------------------
info "FIX 3: Adding stop/start sddm and --runtime unmask to sudoers..."
SUDOERS_FILE="/etc/sudoers.d/gaming-session-switch"
if [[ -f "$SUDOERS_FILE" ]]; then
  NEEDS_UPDATE=0
  
  if ! sudo grep -q "systemctl stop sddm" "$SUDOERS_FILE"; then
    NEEDS_UPDATE=1
  fi
  
  if ! sudo grep -q "unmask --runtime" "$SUDOERS_FILE"; then
    NEEDS_UPDATE=1
  fi
  
  if [[ $NEEDS_UPDATE -eq 1 ]]; then
    sudo cp "$SUDOERS_FILE" "${SUDOERS_FILE}.bak"
    
    # Add stop/start if missing
    if ! sudo grep -q "systemctl stop sddm" "$SUDOERS_FILE"; then
      sudo bash -c "cat >> '$SUDOERS_FILE'" << 'SUDOERS_SDDM'
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start sddm
SUDOERS_SDDM
      info "  Added stop/start sddm to sudoers"
    fi
    
    # Add --runtime unmask if missing
    if ! sudo grep -q "unmask --runtime" "$SUDOERS_FILE"; then
      sudo bash -c "cat >> '$SUDOERS_FILE'" << 'SUDOERS_UNMASK'
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
SUDOERS_UNMASK
      info "  Added --runtime unmask to sudoers"
    fi
    
    sudo chmod 0440 "$SUDOERS_FILE"
    
    # Validate
    if sudo visudo -c -f "$SUDOERS_FILE" 2>/dev/null; then
      info "  Backup at: ${SUDOERS_FILE}.bak"
    else
      err "  Sudoers validation failed! Restoring backup..."
      sudo mv "${SUDOERS_FILE}.bak" "$SUDOERS_FILE"
    fi
  else
    info "  All rules already present in sudoers"
  fi
else
  err "  Not found: $SUDOERS_FILE"
fi
echo ""

# --------------------------------------------------------------------------
# FIX 4: Make gaming-session-switch detect Hyprland session dynamically
# --------------------------------------------------------------------------
# WHY: The original script hardcodes Session=hyprland-uwsm. If Omarchy ever
#       renames the session (e.g. to just "hyprland" or "Hyprland"), the
#       switch back to desktop writes a session name that doesn't exist,
#       and SDDM falls back to whatever else is available.
#       The fix checks /usr/share/wayland-sessions/ at runtime to find the
#       actual Hyprland session file name.
# --------------------------------------------------------------------------
info "FIX 4: Making gaming-session-switch detect session name dynamically..."
SESSION_HELPER="/usr/local/bin/gaming-session-switch"
if [[ -f "$SESSION_HELPER" ]]; then
  sudo cp "$SESSION_HELPER" "${SESSION_HELPER}.pre-hotfix"
  info "  Backed up to: ${SESSION_HELPER}.pre-hotfix"
  sudo tee "$SESSION_HELPER" > /dev/null << 'SESSION_HELPER_SCRIPT'
#!/bin/bash
CONF="/etc/sddm.conf.d/zz-gaming-session.conf"
if [[ ! -f "$CONF" ]]; then
  echo "Error: Config file not found: $CONF" >&2
  exit 1
fi

detect_hyprland_session() {
  # Find the actual Hyprland session name from installed .desktop files
  local session_file
  for candidate in hyprland-uwsm hyprland Hyprland; do
    if [[ -f "/usr/share/wayland-sessions/${candidate}.desktop" ]]; then
      echo "$candidate"
      return
    fi
  done
  # Fallback: search for any desktop file mentioning hyprland
  session_file=$(grep -rl -m1 -i 'hyprland' /usr/share/wayland-sessions/ 2>/dev/null | head -1)
  if [[ -n "$session_file" ]]; then
    basename "$session_file" .desktop
    return
  fi
  echo "hyprland-uwsm"  # last resort fallback
}

case "$1" in
  gaming)
    sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "$CONF"
    echo "Session set to: gaming mode"
    ;;
  desktop)
    DESKTOP_SESSION=$(detect_hyprland_session)
    sed -i "s/^Session=.*/Session=$DESKTOP_SESSION/" "$CONF"
    echo "Session set to: $DESKTOP_SESSION"
    ;;
  *)
    echo "Usage: $0 {gaming|desktop}" >&2
    exit 1
    ;;
esac
SESSION_HELPER_SCRIPT
  sudo chmod +x "$SESSION_HELPER"
  info "  Patched: $SESSION_HELPER"
else
  err "  Not found: $SESSION_HELPER"
fi
echo ""

# --------------------------------------------------------------------------
# FIX 5: Restore gamescope cap_sys_nice (gets stripped on package update)
# --------------------------------------------------------------------------
# WHY: Every time pacman upgrades the gamescope package, it installs a
#       fresh binary that doesn't have the capability. Without it,
#       gamescope can't set realtime scheduling priority.
# --------------------------------------------------------------------------
info "FIX 5: Checking gamescope capabilities..."
if command -v gamescope &>/dev/null; then
  if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
    sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)"
    info "  Restored cap_sys_nice on gamescope"
  else
    info "  cap_sys_nice already set"
  fi
fi
echo ""

# --------------------------------------------------------------------------
# FIX 6: Install pacman hook so future updates auto-fix
# --------------------------------------------------------------------------
# WHY: This creates /etc/pacman.d/hooks/gaming-mode.hook which triggers
#       after gamescope/sddm/gamescope-session updates. It runs a script
#       that re-applies the cap, re-disables plasma.desktop, restores the
#       session desktop file, and restores os-session-select if overwritten.
#       This is what makes the setup survive updates without manual work.
# --------------------------------------------------------------------------
info "FIX 6: Installing pacman hook for update survival..."
sudo mkdir -p /etc/pacman.d/hooks

sudo tee /etc/pacman.d/hooks/gaming-mode.hook > /dev/null << 'PACMAN_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = gamescope
Target = gamescope-session-git
Target = gamescope-session-steam-git
Target = sddm
Target = heroic-games-launcher-bin

[Action]
Description = Restoring Gaming Mode configuration after update...
When = PostTransaction
Exec = /usr/local/bin/gaming-mode-post-update
NeedsTargets
PACMAN_HOOK

sudo tee /usr/local/bin/gaming-mode-post-update > /dev/null << 'POST_UPDATE'
#!/bin/bash
LOG_TAG="gaming-mode-post-update"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

# Restore gamescope cap_sys_nice
if command -v gamescope &>/dev/null; then
  if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
    setcap 'cap_sys_nice=eip' "$(command -v gamescope)" 2>/dev/null && \
      log "Restored cap_sys_nice on gamescope" || \
      log "WARNING: Failed to restore cap_sys_nice on gamescope"
  fi
fi

# Restore custom session desktop file if removed
SESSION_DESKTOP="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
if [[ ! -f "$SESSION_DESKTOP" ]]; then
  cat > "$SESSION_DESKTOP" << 'DESK'
[Desktop Entry]
Name=Gaming Mode (ChimeraOS)
Comment=Steam Big Picture with ChimeraOS gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
DESK
  log "Restored $SESSION_DESKTOP"
fi

# Re-disable competing sessions that may have been reinstalled
for unwanted in plasma.desktop gnome.desktop gnome-wayland.desktop kde-plasma.desktop; do
  if [[ -f "/usr/share/wayland-sessions/$unwanted" ]]; then
    mv "/usr/share/wayland-sessions/$unwanted" "/usr/share/wayland-sessions/${unwanted}.disabled" 2>/dev/null && \
      log "Disabled competing session: $unwanted"
  fi
done

# Restore os-session-select if overwritten by a package
OS_SELECT="/usr/lib/os-session-select"
if [[ -f "$OS_SELECT" ]] && ! grep -q "gaming-session-switch" "$OS_SELECT" 2>/dev/null; then
  cat > "$OS_SELECT" << 'OSSEL'
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || {
  echo "Warning: Failed to update session config"
}
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n systemctl restart sddm &>/dev/null &
disown
exit 0
OSSEL
  chmod +x "$OS_SELECT"
  log "Restored custom os-session-select"
fi

# Re-patch Heroic for Gamescope if it was updated
HEROIC_PATCH="/usr/local/bin/patch-heroic-gamescope"
HEROIC_ASAR="/opt/Heroic/resources/app.asar"
if [[ -f "$HEROIC_PATCH" ]] && [[ -f "$HEROIC_ASAR" ]]; then
  # Check if patch is needed (not already patched)
  if ! npx --yes asar extract "$HEROIC_ASAR" /tmp/heroic-check-$$ &>/dev/null; then
    log "Could not extract Heroic asar to check patch status"
  elif ! grep -q 'ozone-platform=x11' /tmp/heroic-check-$$/build/main/main.js 2>/dev/null; then
    rm -rf /tmp/heroic-check-$$
    log "Re-patching Heroic for Gamescope..."
    if "$HEROIC_PATCH"; then
      log "Heroic re-patched successfully"
    else
      log "WARNING: Heroic patch returned non-zero (may need manual intervention)"
    fi
  else
    rm -rf /tmp/heroic-check-$$
    log "Heroic already patched for Gamescope"
  fi
fi

log "Gaming Mode post-update complete"
POST_UPDATE

sudo chmod +x /usr/local/bin/gaming-mode-post-update
info "  Created pacman hook and post-update script"
echo ""

# --------------------------------------------------------------------------
# FIX 7: Suppress Vulkan swapchain error popups in gamescope
# --------------------------------------------------------------------------
# WHY: When launching Heroic/Electron games in gamescope, the WSI Vulkan layer
#       shows zenity error dialogs about "queuePresentKHR attempting to present
#       to a non-hooked swapchain". The games work fine after clicking OK, but
#       these popups are annoying. GAMESCOPE_ZENITY_DISABLE=1 suppresses them.
# --------------------------------------------------------------------------
info "FIX 7: Suppressing gamescope Vulkan swapchain error popups..."
GAMESCOPE_ENV="$HOME/.config/environment.d/gamescope-session-plus.conf"
if [[ -f "$GAMESCOPE_ENV" ]]; then
    if ! grep -q "GAMESCOPE_ZENITY_DISABLE" "$GAMESCOPE_ENV"; then
        echo "GAMESCOPE_ZENITY_DISABLE=1" >> "$GAMESCOPE_ENV"
        info "  Added GAMESCOPE_ZENITY_DISABLE=1 to gamescope session config"
    else
        info "  GAMESCOPE_ZENITY_DISABLE already configured"
    fi
else
    warn "  Gamescope session config not found: $GAMESCOPE_ENV"
    warn "  (This is normal if you haven't booted into Gaming Mode yet)"
fi
echo ""

# --------------------------------------------------------------------------
# SUMMARY
# --------------------------------------------------------------------------
echo "================================================================"
echo "  ALL FIXES APPLIED"
echo "================================================================"
echo ""
echo "  1. Disabled plasma.desktop (no more KDE fallback)"
echo "  2. Fixed switch-to-desktop (restart + --runtime unmask for hibernation)"
echo "  3. Added stop/start sddm and --runtime unmask to sudoers"
echo "  4. Dynamic Hyprland session detection (survives renames)"
echo "  5. Restored gamescope cap_sys_nice if needed"
echo "  6. Installed pacman hook (auto-fixes after future updates)"
echo "  7. Suppressed gamescope Vulkan swapchain error popups"
echo ""
echo "  You can now safely reboot."
echo ""
echo "  TO UNDO ALL FIXES if something goes wrong:"
echo "    sudo mv /usr/share/wayland-sessions/plasma.desktop.disabled /usr/share/wayland-sessions/plasma.desktop"
echo "    sudo cp /usr/local/bin/switch-to-desktop.pre-hotfix /usr/local/bin/switch-to-desktop"
echo "    sudo cp /usr/local/bin/gaming-session-switch.pre-hotfix /usr/local/bin/gaming-session-switch"
echo "    sudo cp /etc/sudoers.d/gaming-session-switch.bak /etc/sudoers.d/gaming-session-switch"
echo "    sudo setcap -r \$(which gamescope)"
echo "    sudo rm /etc/pacman.d/hooks/gaming-mode.hook /usr/local/bin/gaming-mode-post-update"
echo "    # To undo FIX 7: edit ~/.config/environment.d/gamescope-session-plus.conf"
echo "================================================================"
echo ""
