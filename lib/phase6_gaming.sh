#!/bin/bash
# Phase 6: Gaming Tools (optional)
# Gaming Mode is provided by the DeckShift submodule (templates/deckshift/),
# forked to Cliffback/deckshift-z13 with the Z13-specific fixes on the z13
# branch. DeckShift replaces the old bundled Super_shift_S_release.sh +
# gaming-mode-hotfix.sh pair.

# DeckShift's own installer/verifier, run from the submodule.
DECKSHIFT_SCRIPT="$SCRIPT_DIR/templates/deckshift/deckshift.sh"

phase6_check() {
    deckshift_ready \
        && is_pkg_installed gamescope \
        && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]] \
        && deckshift_applied \
        && [[ -d "$HOME/homebrew/services" ]] \
        && [[ -d "$HOME/homebrew/plugins/SimpleDeckyTDP" ]] \
        && is_pkg_installed heroic-games-launcher-bin \
        && [[ -f "$HOME/Applications/EmuDeck.AppImage" ]] \
        && [[ -f "$HOME/Applications/.emudeck-version" ]]
}

# Verify gaming mode health — runs even when phase is skipped.
# Delegates to DeckShift's own --verify, which knows the current file layout
# (Lua keybind, consolidated pacman hook, portal recovery, control panel).
# Args: $1 = "always_prompt" to always offer the installer (used after fresh install)
# Returns 0 if all checks pass, 1 if issues found
phase6_verify() {
    local always_prompt="${1:-}"

    # Only run if gamescope is installed
    is_pkg_installed gamescope || return 0

    if ! deckshift_ready; then
        warn "DeckShift submodule not checked out (templates/deckshift empty)"
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] Would run: git submodule update --init --recursive"
        elif ensure_deckshift_submodule; then
            success "DeckShift submodule initialised."
        else
            warn "Could not initialise the submodule — run: git submodule update --init --recursive"
            return 1
        fi
    fi

    local issues=0
    local verify_output=""
    local verify_rc=0

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] Would run: $DECKSHIFT_SCRIPT --verify"
    else
        verify_output=$(bash "$DECKSHIFT_SCRIPT" --verify 2>&1) || verify_rc=$?
        if [[ $verify_rc -ne 0 ]]; then
            issues=1
            echo "$verify_output" | grep -E '✗|⚠|MISSING|NOT|WARN' | head -20 || true
        fi
    fi

    if [[ $issues -eq 0 ]]; then
        success "Gaming mode setup verified."
    else
        warn "DeckShift verification reported issues (see above)."
    fi

    # Prompt for the installer if issues found OR if always_prompt is set
    if [[ $issues -gt 0 ]] || [[ "$always_prompt" == "always_prompt" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] Would prompt to re-run DeckShift installer"
        elif ask_yn "Re-run the DeckShift installer to fix these? (Recommended)"; then
            bash "$DECKSHIFT_SCRIPT"
            success "DeckShift installer completed."
        fi
    fi

    [[ $issues -eq 0 ]]
}

phase6_run() {
    local gamescope_ran=0

    # --- Gamescope (DeckShift gaming mode) ---
    # A pre-migration install has gamescope + a session entry but was set up by
    # the retired Super_shift_S_release.sh + hotfix pair, so it lacks the
    # DeckShift marker. Treat that as "needs the installer", not "already done".
    if is_pkg_installed gamescope \
        && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]] \
        && deckshift_applied; then
        success "Gamescope already installed (DeckShift)."
    elif [[ $DRY_RUN -eq 1 ]]; then
        if is_pkg_installed gamescope; then
            info "Would prompt to migrate Gaming Mode to DeckShift"
        else
            info "Would prompt to install Gamescope (Steam Gaming Mode) via DeckShift"
        fi
    else
        if ! deckshift_ready && ! ensure_deckshift_submodule; then
            warn "DeckShift submodule unavailable — skipping Gaming Mode install."
            warn "Run: git submodule update --init --recursive"
        else
            local gs_prompt="Install Gamescope (Steam Gaming Mode)?"
            if is_pkg_installed gamescope; then
                warn "Gaming Mode was set up by the retired Super_shift_S_release.sh +"
                warn "hotfix stack. DeckShift replaces it (Lua keybind, portal recovery,"
                warn "consolidated pacman hook, power-profile restore)."
                gs_prompt="Migrate Gaming Mode to DeckShift?"
            fi
            if ask_yn "$gs_prompt"; then
                gamescope_ran=1
                info "Running DeckShift installer..."
                bash "$DECKSHIFT_SCRIPT"
                success "Gamescope installed."
            fi
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
                        # Install the patch script system-wide for the DeckShift pacman hook
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
    # Otherwise: runs verification, prompts for installer only if issues found
    if [[ $gamescope_ran -eq 0 ]]; then
        phase6_verify || true
    fi
}
