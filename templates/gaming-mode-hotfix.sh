#!/bin/bash
# ============================================================================
#  Gaming Mode Hotfix — run after Gaming Mode installation
#  Applies fixes that aren't in the main Super_shift_S_release.sh script
# ============================================================================
set -euo pipefail

VERSION="1.3.3"

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

# ---------------------------------------------------------------------------
# CLI Argument Parsing
# ---------------------------------------------------------------------------
CHECK_ONLY=false

# HDR fix is disabled by default because the ROG Flow Z13's internal panel
# only has ~500 nits peak brightness, which makes HDR look worse than SDR.
# Set to false to enable (useful for external HDR monitors with higher brightness).
# Can also override at runtime: SKIP_HDR_FIX=false ./gaming-mode-hotfix.sh
SKIP_HDR_FIX=${SKIP_HDR_FIX:-true}

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
  3. Configure refresh rates for ROG Flow Z13 180Hz panel
  4. Install pacman hook for surviving package updates

Optional (disabled by default):
  HDR session override - Enable with: SKIP_HDR_FIX=false ./gaming-mode-hotfix.sh

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
      ((++FIXES_APPLIED))
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
      ((++FIXES_APPLIED))
    fi
  done
  echo ""
fi

# --------------------------------------------------------------------------
# FIX 3: Configure refresh rates for ROG Flow Z13 180Hz panel
# --------------------------------------------------------------------------
# WHY: The ROG Flow Z13 has a 180Hz panel. Without these variables, Steam
#       may not show the correct framerate options in the UI. 
#       - CUSTOM_REFRESH_RATES: passed to gamescope as --custom-refresh-rates
#       - STEAM_DISPLAY_REFRESH_LIMITS: tells Steam UI what range to show
# --------------------------------------------------------------------------
GAMESCOPE_ENV="$HOME/.config/environment.d/gamescope-session-plus.conf"

if ! $CHECK_ONLY; then
  info "FIX 3: Configuring refresh rates for ROG Flow Z13 180Hz panel..."
  if [[ -f "$GAMESCOPE_ENV" ]]; then
    REFRESH_UPDATED=0
    
    if ! grep -q "^CUSTOM_REFRESH_RATES=" "$GAMESCOPE_ENV" 2>/dev/null; then
      echo "CUSTOM_REFRESH_RATES=60,120,180" >> "$GAMESCOPE_ENV"
      info "  Added CUSTOM_REFRESH_RATES=60,120,180"
      REFRESH_UPDATED=1
    else
      info "  CUSTOM_REFRESH_RATES already configured"
    fi
    
    if ! grep -q "^STEAM_DISPLAY_REFRESH_LIMITS=" "$GAMESCOPE_ENV" 2>/dev/null; then
      echo "STEAM_DISPLAY_REFRESH_LIMITS=60,180" >> "$GAMESCOPE_ENV"
      info "  Added STEAM_DISPLAY_REFRESH_LIMITS=60,180"
      REFRESH_UPDATED=1
    else
      info "  STEAM_DISPLAY_REFRESH_LIMITS already configured"
    fi
    
    if [[ $REFRESH_UPDATED -eq 1 ]]; then
      ((++FIXES_APPLIED))
    fi
  else
    warn "  Gamescope session config not found: $GAMESCOPE_ENV"
    warn "  (This is normal if you haven't booted into Gaming Mode yet)"
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
  
  if [[ -f /etc/pacman.d/hooks/gaming-mode.hook ]] && [[ -x /usr/local/bin/gaming-mode-post-update ]]; then
    info "  Pacman hook already installed"
  else
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
    ((++FIXES_APPLIED))
  fi
  echo ""
fi

# --------------------------------------------------------------------------
# Disable HDR in Heroic (when SKIP_HDR_FIX=true)
# --------------------------------------------------------------------------
# WHY: The ROG Flow Z13's panel only has ~500 nits peak brightness, which
#       makes HDR look worse than SDR. Setting DXVK_HDR=0 in Heroic's config
#       prevents games from trying to use HDR output.
# --------------------------------------------------------------------------
HEROIC_CONFIG="$HOME/.config/heroic/config.json"

if ! $CHECK_ONLY && $SKIP_HDR_FIX; then
  if [[ -f "$HEROIC_CONFIG" ]] && command -v jq &>/dev/null; then
    if ! jq -e '.defaultSettings.enviromentOptions[]? | select(.key == "DXVK_HDR")' "$HEROIC_CONFIG" &>/dev/null; then
      info "Setting DXVK_HDR=0 in Heroic config (disabling HDR for games)..."
      # Add DXVK_HDR=0 to enviromentOptions array
      jq '.defaultSettings.enviromentOptions += [{"key": "DXVK_HDR", "value": "0"}]' "$HEROIC_CONFIG" > "${HEROIC_CONFIG}.tmp" && \
        mv "${HEROIC_CONFIG}.tmp" "$HEROIC_CONFIG"
      info "  Added DXVK_HDR=0 to Heroic environment variables"
      ((++FIXES_APPLIED))
    fi
  fi
fi

# --------------------------------------------------------------------------
# OPTIONAL: Install HDR session override for ROG Flow Z13
# --------------------------------------------------------------------------
# WHY: The ROG Flow Z13 2025's panel EDID is deficient - it has HDR Static
#       Metadata but is missing PQ (ST2084) EOTF and BT.2020 RGB colorimetry.
#       Gamescope requires both for automatic HDR detection. This override
#       uses X11 atoms to force HDR10 PQ output, equivalent to the CLI flag
#       --hdr-debug-force-output. The panel can physically handle HDR10
#       (10-bit, 100% DCI-P3, 500 nits) despite the broken EDID.
#
# NOTE: Disabled by default because the panel's ~500 nits peak brightness
#       makes HDR look worse than SDR. Enable with SKIP_HDR_FIX=false for
#       external HDR monitors with better peak brightness.
# --------------------------------------------------------------------------
HDR_SESSION_DIR="$HOME/.config/gamescope-session-plus/sessions.d"
HDR_SESSION_FILE="$HDR_SESSION_DIR/steam"
HDR_TEMPLATE="$(dirname "${BASH_SOURCE[0]}")/gamescope-hdr-session-steam"

if ! $CHECK_ONLY && ! $SKIP_HDR_FIX; then
  echo "================================================================"
  echo "  OPTIONAL: HDR SESSION OVERRIDE"
  echo "================================================================"
  echo ""
  info "Installing HDR session override for ROG Flow Z13..."
  
  if [[ ! -f "$HDR_TEMPLATE" ]]; then
    warn "  Template not found: $HDR_TEMPLATE"
    warn "  (Run this script from the omarchy-rog-z13-setup directory)"
  elif [[ -f "$HDR_SESSION_FILE" ]] && grep -q "GAMESCOPE_DEBUG_FORCE_HDR10_PQ_OUTPUT" "$HDR_SESSION_FILE" 2>/dev/null; then
    info "  HDR session override already installed"
  else
    if [[ -f "$HDR_SESSION_FILE" ]]; then
      warn "  Session override exists but doesn't have HDR fix - backing up and replacing"
      cp "$HDR_SESSION_FILE" "${HDR_SESSION_FILE}.bak.$(date +%s)"
    fi
    mkdir -p "$HDR_SESSION_DIR"
    cp "$HDR_TEMPLATE" "$HDR_SESSION_FILE"
    info "  Created HDR session override at $HDR_SESSION_FILE"
    ((++FIXES_APPLIED))
  fi
  echo ""
  warn "REMINDER: Check Heroic Settings -> Other -> Environment Variables"
  warn "          Remove DXVK_HDR=0 if you want HDR in Heroic games."
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

# Check refresh rates
if [[ -f "$GAMESCOPE_ENV" ]]; then
  if grep -q "^CUSTOM_REFRESH_RATES=" "$GAMESCOPE_ENV" 2>/dev/null; then
    info "  [OK] CUSTOM_REFRESH_RATES configured"
  else
    warn "  [WARN] CUSTOM_REFRESH_RATES not set"
    verify_ok=false
  fi
  if grep -q "^STEAM_DISPLAY_REFRESH_LIMITS=" "$GAMESCOPE_ENV" 2>/dev/null; then
    info "  [OK] STEAM_DISPLAY_REFRESH_LIMITS configured"
  else
    warn "  [WARN] STEAM_DISPLAY_REFRESH_LIMITS not set"
    verify_ok=false
  fi
fi

# Check pacman hook and post-update script
if [[ -f /etc/pacman.d/hooks/gaming-mode.hook ]] && [[ -x /usr/local/bin/gaming-mode-post-update ]]; then
  info "  [OK] Pacman hook installed"
else
  warn "  [WARN] Pacman hook not installed"
  verify_ok=false
fi

# Check HDR session override (only if HDR fix is enabled)
if ! $SKIP_HDR_FIX; then
  if [[ -f "$HOME/.config/gamescope-session-plus/sessions.d/steam" ]]; then
    if grep -q "GAMESCOPE_DEBUG_FORCE_HDR10_PQ_OUTPUT" "$HOME/.config/gamescope-session-plus/sessions.d/steam" 2>/dev/null; then
      info "  [OK] HDR session override installed"
    else
      warn "  [WARN] HDR session override exists but missing HDR fix"
      verify_ok=false
    fi
  else
    warn "  [WARN] HDR session override not installed"
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
echo "    3. Configure refresh rates for ROG Flow Z13 180Hz panel"
echo "    4. Install pacman hook (auto-fixes after package updates)"
if ! $SKIP_HDR_FIX; then
  echo ""
  echo "  Optional:"
  echo "    * HDR session override installed (force HDR10 output)"
fi
echo ""
if ! $CHECK_ONLY; then
  echo "  You can now safely reboot or enter Gaming Mode."
  echo ""
fi
