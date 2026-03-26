#!/bin/bash
# ============================================================================
#  Gaming Mode Hotfix — run after Gaming Mode installation
#  Applies fixes that aren't in the main Super_shift_S_release.sh script
# ============================================================================
set -euo pipefail

VERSION="1.1.0"

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

# ---------------------------------------------------------------------------
# CLI Argument Parsing
# ---------------------------------------------------------------------------
CHECK_ONLY=false

show_help() {
  cat << EOF
Gaming Mode Hotfix v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Applies fixes that aren't in the main Super_shift_S_release.sh script.

Options:
  --check     Verify current state without applying any fixes
  --help      Show this help message
  --version   Show version number

Fixes applied:
  1. Restore cap_sys_nice on gamescope (for frame pacing)
  2. Disable competing session desktop files (plasma, gnome, kde)
  3. Add stop/start sddm + --runtime unmask to sudoers
  4. Install pacman hook for surviving package updates
  5. Suppress gamescope Vulkan swapchain error popups

EOF
  exit 0
}

show_version() {
  echo "Gaming Mode Hotfix v${VERSION}"
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --check)    CHECK_ONLY=true ;;
    --help)     show_help ;;
    --version)  show_version ;;
    *)
      err "Unknown option: $arg"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo ""
echo "================================================================"
if $CHECK_ONLY; then
echo "  GAMING MODE HOTFIX — CHECK MODE (no changes)"
else
echo "  GAMING MODE HOTFIX"
fi
echo "================================================================"
echo ""

if $CHECK_ONLY; then
  info "Running in check mode — verifying current state only"
  echo ""
fi

FIXES_APPLIED=0

# --------------------------------------------------------------------------
# FIX 1: Restore cap_sys_nice on gamescope
# --------------------------------------------------------------------------
# WHY: gamescope needs cap_sys_nice to set real-time scheduling priorities
#       for smooth frame pacing. This capability gets stripped every time
#       gamescope is updated via pacman. The pacman hook (FIX 4) handles
#       future updates, but we need to set it now if it's missing.
# --------------------------------------------------------------------------
if ! $CHECK_ONLY; then
  info "FIX 1: Checking gamescope cap_sys_nice..."
  if command -v gamescope &>/dev/null; then
    GAMESCOPE_PATH="$(command -v gamescope)"
    if ! getcap "$GAMESCOPE_PATH" 2>/dev/null | grep -q 'cap_sys_nice'; then
      sudo setcap 'cap_sys_nice=eip' "$GAMESCOPE_PATH"
      info "  Restored cap_sys_nice on $GAMESCOPE_PATH"
      ((FIXES_APPLIED++))
    else
      info "  cap_sys_nice already set"
    fi
  else
    warn "  gamescope not found (not installed yet?)"
  fi
  echo ""
fi

# --------------------------------------------------------------------------
# FIX 2: Disable competing session desktop files
# --------------------------------------------------------------------------
# WHY: SDDM autologin tries your configured session. If anything goes wrong
#       (session switch fails silently, session name doesn't match), SDDM
#       shows its greeter with all available sessions. plasma.desktop or
#       gnome.desktop sitting there as options can cause SDDM to auto-pick
#       them as a fallback with Relogin=true.
#       By disabling them, the ONLY sessions available are Hyprland and
#       Gamescope — so even failures land somewhere useful.
# --------------------------------------------------------------------------
if ! $CHECK_ONLY; then
  info "FIX 2: Disabling competing session desktop files..."
  for unwanted in plasma.desktop gnome.desktop gnome-wayland.desktop kde-plasma.desktop; do
    path="/usr/share/wayland-sessions/$unwanted"
    if [[ -f "$path" ]]; then
      sudo mv "$path" "${path}.disabled"
      info "  Disabled: $unwanted"
      ((FIXES_APPLIED++))
    fi
  done
  echo ""
fi

# --------------------------------------------------------------------------
# FIX 3: Add stop/start sddm + --runtime unmask to sudoers
# --------------------------------------------------------------------------
# WHY: Belt and suspenders. The main script uses "restart" in switch-to-desktop,
#       but adding stop/start to sudoers means if any other code path (like a
#       future update to os-session-select or a manual debug session) tries
#       stop/start, it won't silently fail.
#
# ALSO: The unmask --runtime command needs to be in sudoers for the hibernation
#       fix to work. Without it, the unmask command fails silently.
# --------------------------------------------------------------------------
if ! $CHECK_ONLY; then
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
        ((FIXES_APPLIED++))
      fi
      
      # Add --runtime unmask if missing
      if ! sudo grep -q "unmask --runtime" "$SUDOERS_FILE"; then
        sudo bash -c "cat >> '$SUDOERS_FILE'" << 'SUDOERS_UNMASK'
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
SUDOERS_UNMASK
        info "  Added --runtime unmask to sudoers"
        ((FIXES_APPLIED++))
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
      info "  All sudoers rules already present"
    fi
  else
    warn "  Not found: $SUDOERS_FILE (main script may not have run yet)"
  fi
  echo ""
fi

# --------------------------------------------------------------------------
# FIX 4: Install pacman hook so future updates auto-fix
# --------------------------------------------------------------------------
# WHY: This creates /etc/pacman.d/hooks/gaming-mode.hook which triggers
#       after gamescope/sddm/gamescope-session updates. It runs a script
#       that re-applies the cap, re-disables competing sessions, restores
#       the session desktop file, and restores os-session-select if overwritten.
#       This is what makes the setup survive updates without manual work.
# --------------------------------------------------------------------------
if ! $CHECK_ONLY; then
  info "FIX 4: Installing pacman hook for update survival..."
  
  if [[ -f /etc/pacman.d/hooks/gaming-mode.hook ]]; then
    info "  Pacman hook already exists, updating..."
  fi
  
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
sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n /usr/bin/systemctl restart sddm &>/dev/null &
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
  ((FIXES_APPLIED++))
  echo ""
fi

# --------------------------------------------------------------------------
# FIX 5: Suppress Vulkan swapchain error popups in gamescope
# --------------------------------------------------------------------------
# WHY: When launching Heroic/Electron games in gamescope, the WSI Vulkan layer
#       shows zenity error dialogs about "queuePresentKHR attempting to present
#       to a non-hooked swapchain". The games work fine after clicking OK, but
#       these popups are annoying. GAMESCOPE_ZENITY_DISABLE=1 suppresses them.
# --------------------------------------------------------------------------
if ! $CHECK_ONLY; then
  info "FIX 5: Suppressing gamescope Vulkan swapchain error popups..."
  GAMESCOPE_ENV="$HOME/.config/environment.d/gamescope-session-plus.conf"
  if [[ -f "$GAMESCOPE_ENV" ]]; then
      if ! grep -q "GAMESCOPE_ZENITY_DISABLE" "$GAMESCOPE_ENV"; then
          echo "GAMESCOPE_ZENITY_DISABLE=1" >> "$GAMESCOPE_ENV"
          info "  Added GAMESCOPE_ZENITY_DISABLE=1 to gamescope session config"
          ((FIXES_APPLIED++))
      else
          info "  GAMESCOPE_ZENITY_DISABLE already configured"
      fi
  else
      warn "  Gamescope session config not found: $GAMESCOPE_ENV"
      warn "  (This is normal if you haven't booted into Gaming Mode yet)"
  fi
  echo ""
fi

# --------------------------------------------------------------------------
# VERIFICATION
# --------------------------------------------------------------------------
echo "================================================================"
echo "  VERIFICATION"
echo "================================================================"
echo ""

verify_ok=true

# Check gamescope cap_sys_nice
if command -v gamescope &>/dev/null; then
  if getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
    info "  [OK] gamescope has cap_sys_nice"
  else
    warn "  [WARN] gamescope missing cap_sys_nice"
    verify_ok=false
  fi
fi

# Check pacman hook
if [[ -f /etc/pacman.d/hooks/gaming-mode.hook ]]; then
  info "  [OK] Pacman hook installed"
else
  warn "  [WARN] Pacman hook not installed"
  verify_ok=false
fi

# Check post-update script
if [[ -x /usr/local/bin/gaming-mode-post-update ]]; then
  info "  [OK] Post-update script installed"
else
  warn "  [WARN] Post-update script not installed"
  verify_ok=false
fi

# Check competing sessions disabled
competing_found=false
for session in plasma.desktop gnome.desktop gnome-wayland.desktop kde-plasma.desktop; do
  if [[ -f "/usr/share/wayland-sessions/$session" ]]; then
    warn "  [WARN] Competing session still enabled: $session"
    competing_found=true
    verify_ok=false
  fi
done
if ! $competing_found; then
  info "  [OK] No competing sessions enabled"
fi

# Check sudoers entries
if [[ -f /etc/sudoers.d/gaming-session-switch ]]; then
  if sudo grep -q "systemctl stop sddm" /etc/sudoers.d/gaming-session-switch 2>/dev/null; then
    info "  [OK] Sudoers has stop/start sddm"
  else
    warn "  [WARN] Sudoers missing stop/start sddm"
    verify_ok=false
  fi
  if sudo grep -q "unmask --runtime" /etc/sudoers.d/gaming-session-switch 2>/dev/null; then
    info "  [OK] Sudoers has --runtime unmask"
  else
    warn "  [WARN] Sudoers missing --runtime unmask"
    verify_ok=false
  fi
fi

# Check GAMESCOPE_ZENITY_DISABLE
if [[ -f "$HOME/.config/environment.d/gamescope-session-plus.conf" ]]; then
  if grep -q "GAMESCOPE_ZENITY_DISABLE=1" "$HOME/.config/environment.d/gamescope-session-plus.conf" 2>/dev/null; then
    info "  [OK] GAMESCOPE_ZENITY_DISABLE configured"
  else
    warn "  [WARN] GAMESCOPE_ZENITY_DISABLE not set"
    verify_ok=false
  fi
fi

echo ""

# --------------------------------------------------------------------------
# SUMMARY
# --------------------------------------------------------------------------
echo "================================================================"
if $CHECK_ONLY; then
  if $verify_ok; then
    echo "  CHECK PASSED — All fixes already applied"
  else
    echo "  CHECK FAILED — Some fixes need to be applied"
    echo "  Run without --check to apply fixes"
  fi
else
  if $verify_ok; then
    echo "  ALL FIXES APPLIED AND VERIFIED"
  else
    echo "  FIXES APPLIED (some verifications failed)"
  fi
fi
echo "================================================================"
echo ""
if ! $CHECK_ONLY; then
  echo "  Applied $FIXES_APPLIED fix(es):"
fi
echo "    1. Restore cap_sys_nice on gamescope (for frame pacing)"
echo "    2. Disable competing session desktop files (plasma, gnome, kde)"
echo "    3. Add stop/start sddm + --runtime unmask to sudoers"
echo "    4. Install pacman hook (auto-fixes after package updates)"
echo "    5. Suppress gamescope Vulkan swapchain error popups"
echo ""
if ! $CHECK_ONLY; then
  echo "  You can now safely reboot or enter Gaming Mode."
  echo ""
fi
