#!/bin/bash
# Phase 6: Gaming Tools (optional)
# Gaming Mode script is now bundled in templates/Super_shift_S_release.sh

phase6_check() {
    # Skip phase only if ALL optional tools are already installed and up-to-date
    is_pkg_installed gamescope \
        && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]] \
        && [[ -d "$HOME/homebrew/services" ]] \
        && [[ -d "$HOME/homebrew/plugins/SimpleDeckyTDP" ]] \
        && is_pkg_installed heroic-games-launcher-bin \
        && [[ -f "$HOME/Applications/EmuDeck.AppImage" ]] \
        && [[ -f "$HOME/Applications/.emudeck-version" ]]
}

# Verify gaming mode health — runs even when phase is skipped
# Args: $1 = "always_prompt" to always offer hotfix (used after fresh install)
# Returns 0 if all checks pass, 1 if issues found
phase6_verify() {
    local always_prompt="${1:-}"
    
    # Only run if gamescope is installed
    is_pkg_installed gamescope || return 0

    local issues=0

    if ! has_gamescope_caps; then
        warn "gamescope missing cap_sys_nice capability (may cause performance issues)"
        ((issues++))
    fi

    if ! has_gaming_mode_hook; then
        warn "Pacman hook not installed (fixes won't survive package updates)"
        ((issues++))
    fi

    if [[ ! -f /usr/local/bin/gaming-session-switch ]]; then
        warn "gaming-session-switch script not found (session switching may fail)"
        ((issues++))
    fi

    if [[ ! -f /usr/local/bin/switch-to-desktop ]]; then
        warn "switch-to-desktop script not found (returning to desktop may fail)"
        ((issues++))
    fi

    if ! has_hdr_session_override; then
        warn "HDR session override not installed (HDR may not work for non-Steam games)"
        ((issues++))
    fi

    if ! has_refresh_rates_configured; then
        warn "Refresh rates not configured (Steam may not show correct framerate options)"
        ((issues++))
    fi

    if [[ $issues -eq 0 ]]; then
        success "Gaming mode setup verified."
    else
        warn "Found $issues issue(s) with gaming mode setup."
    fi

    # Prompt for hotfix if issues found OR if always_prompt is set
    if [[ $issues -gt 0 ]] || [[ "$always_prompt" == "always_prompt" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] Would prompt to run gaming-mode-hotfix.sh"
        elif ask_yn "Run gaming mode hotfix script? (Recommended)"; then
            bash "$SCRIPT_DIR/templates/gaming-mode-hotfix.sh"
            success "Gaming mode hotfix applied."
        fi
    fi

    [[ $issues -eq 0 ]]
}

phase6_run() {
    local gamescope_ran=0

    # --- Gamescope (NO SIGNAL script) ---
    if is_pkg_installed gamescope && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]]; then
        success "Gamescope already installed."
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install Gamescope (Steam Gaming Mode)"
    else
        if ask_yn "Install Gamescope (Steam Gaming Mode)?"; then
            gamescope_ran=1
            info "Running Gaming Mode setup script..."
            bash "$SCRIPT_DIR/templates/Super_shift_S_release.sh"
            success "Gamescope installed."
        fi
    fi

    # --- Verify and optionally fix gaming mode (only if gamescope was just installed) ---
    if [[ $gamescope_ran -eq 1 ]]; then
        phase6_verify always_prompt || true
    fi

    # --- Decky Loader ---
    if [[ -d "$HOME/homebrew/services" ]]; then
        success "Decky Loader already installed."
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install Decky Loader (plugin framework for Gaming Mode)"
    else
        if ask_yn "Install Decky Loader (plugin framework for Gaming Mode)?"; then
            info "Installing Decky Loader..."
            curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh
            success "Decky Loader installed."
        fi
    fi

    # --- SimpleDeckyTDP ---
    if [[ -d "$HOME/homebrew/plugins/SimpleDeckyTDP" ]]; then
        success "SimpleDeckyTDP already installed."
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install SimpleDeckyTDP (TDP control plugin)"
    else
        if ask_yn "Install SimpleDeckyTDP plugin (TDP control)?"; then
            sudo pacman -S --needed --noconfirm 7zip
            info "Installing SimpleDeckyTDP..."
            curl -L https://github.com/aarron-lee/SimpleDeckyTDP/raw/main/install.sh | sh
            success "SimpleDeckyTDP installed."
        fi
    fi

    # --- Heroic Games Launcher ---
    if is_pkg_installed heroic-games-launcher-bin; then
        success "Heroic Games Launcher already installed."
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install Heroic Games Launcher (Epic/GOG/Amazon)"
    else
        if ask_yn "Install Heroic Games Launcher (Epic/GOG/Amazon)?"; then
            yay -S --needed --noconfirm heroic-games-launcher-bin
            success "Heroic Games Launcher installed."
        fi
    fi

    # --- Patch Heroic for Gamescope ---
    if [[ -f /opt/Heroic/resources/app.asar ]]; then
        if heroic_needs_patch; then
            if [[ $DRY_RUN -eq 1 ]]; then
                info "Would prompt to patch Heroic for Gamescope (--ozone-platform=x11)"
            else
                echo ""
                info "Heroic needs patching to work in Gamescope/Gaming Mode."
                info "This adds --ozone-platform=x11 to Steam shortcuts so Electron can render in XWayland."
                if ask_yn "Apply Heroic Gamescope patch?"; then
                    info "Patching Heroic for Gamescope compatibility..."
                    if bash "$SCRIPT_DIR/templates/patch-heroic-gamescope.sh"; then
                        # Install the patch script system-wide for pacman hook
                        sudo cp "$SCRIPT_DIR/templates/patch-heroic-gamescope.sh" /usr/local/bin/patch-heroic-gamescope
                        sudo chmod +x /usr/local/bin/patch-heroic-gamescope
                        success "Heroic patched and patch script installed to /usr/local/bin/"
                    else
                        warn "Heroic patch returned non-zero (may already be patched)"
                    fi
                fi
            fi
        else
            success "Heroic already patched for Gamescope."
        fi
    fi

    # --- EmuDeck ---
    local EMUDECK_APPIMAGE="$HOME/Applications/EmuDeck.AppImage"
    local EMUDECK_VERSION_FILE="$HOME/Applications/.emudeck-version"
    local EMUDECK_API="https://api.github.com/repos/EmuDeck/emudeck-electron/releases/latest"

    if [[ -f "$EMUDECK_APPIMAGE" ]]; then
        # Check if update is available
        local installed_version latest_version latest_url
        installed_version=$(cat "$EMUDECK_VERSION_FILE" 2>/dev/null || echo "unknown")
        latest_version=$(curl -s "$EMUDECK_API" | jq -r '.tag_name' 2>/dev/null || echo "")

        if [[ -z "$latest_version" ]]; then
            # API failed, just report installed
            success "EmuDeck already installed ($installed_version)."
        elif [[ "$installed_version" == "$latest_version" ]]; then
            success "EmuDeck already installed ($installed_version)."
        elif [[ $DRY_RUN -eq 1 ]]; then
            info "Would prompt to update EmuDeck ($installed_version → $latest_version)"
        else
            if ask_yn "Update EmuDeck ($installed_version → $latest_version)?"; then
                latest_url=$(curl -s "$EMUDECK_API" | jq -r '.assets[] | select(.name | endswith(".AppImage")) | .browser_download_url')
                info "Downloading EmuDeck $latest_version..."
                curl -L "$latest_url" -o "$EMUDECK_APPIMAGE"
                chmod +x "$EMUDECK_APPIMAGE"
                echo "$latest_version" > "$EMUDECK_VERSION_FILE"
                success "EmuDeck updated to $latest_version."
            fi
        fi
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install EmuDeck (emulator setup & ROM management)"
    else
        if ask_yn "Install EmuDeck (emulator setup & ROM management)?"; then
            sudo pacman -S --needed --noconfirm bash flatpak fuse2 git jq rsync python steam unzip zenity
            mkdir -p "$HOME/Applications"
            local latest_version latest_url
            latest_version=$(curl -s "$EMUDECK_API" | jq -r '.tag_name')
            latest_url=$(curl -s "$EMUDECK_API" | jq -r '.assets[] | select(.name | endswith(".AppImage")) | .browser_download_url')
            info "Downloading EmuDeck $latest_version..."
            curl -L "$latest_url" -o "$EMUDECK_APPIMAGE"
            chmod +x "$EMUDECK_APPIMAGE"
            echo "$latest_version" > "$EMUDECK_VERSION_FILE"
            success "EmuDeck installed ($latest_version)."
        fi
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        success "Steam Gamescope setup complete."
    fi

    # --- Always verify gaming mode health at end of phase ---
    # In dry-run: shows current health status
    # After fresh install: already ran with always_prompt above
    # Otherwise: runs verification, prompts for hotfix only if issues found
    if [[ $gamescope_ran -eq 0 ]]; then
        phase6_verify || true
    fi
}
