#!/bin/bash
# Phase 6: Steam Gamescope Setup (optional)

GAMESCOPE_URL="https://www.dropbox.com/scl/fo/kyvz9f3hbra5m8wxr1w9k/AI3-P-c1zvWptThe57QSnG4?rlkey=sh4didbdi3cdeglhc2mly0817&st=g6886xpq&dl=1"
TMP_DIR="$SCRIPT_DIR/.tmp"

phase6_check() {
    is_pkg_installed gamescope \
        && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]] \
        && [[ -d "$HOME/homebrew/services" ]] \
        && [[ -d "$HOME/homebrew/plugins/SimpleDeckyTDP" ]] \
        && is_pkg_installed heroic-games-launcher-bin
}

phase6_run() {
    info "Setting up Steam Gamescope..."

    # --- Gamescope (NO SIGNAL script) ---
    if is_pkg_installed gamescope && [[ -f /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop ]]; then
        success "Gamescope already installed."
    else
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would create $TMP_DIR"
            info "[DRY-RUN] would download Dropbox zip to $TMP_DIR/gamescope.zip"
            info "[DRY-RUN] would unzip to $TMP_DIR/gamescope/"
            info "[DRY-RUN] would run NO SIGNAL Gamescope setup script"
        else
            mkdir -p "$TMP_DIR"

            info "Downloading Gamescope setup archive..."
            curl -L -o "$TMP_DIR/gamescope.zip" "$GAMESCOPE_URL"

            info "Extracting archive..."
            unzip -o "$TMP_DIR/gamescope.zip" -d "$TMP_DIR/gamescope"

            chmod +x "$TMP_DIR/gamescope/Super_shift_S_release.sh"

            info "Running NO SIGNAL Gamescope setup script..."
            bash "$TMP_DIR/gamescope/Super_shift_S_release.sh"
        fi
    fi

    # --- Decky Loader ---
    if [[ -d "$HOME/homebrew/services" ]]; then
        success "Decky Loader already installed."
    else
        if ask_yn "Install Decky Loader (plugin framework for Gaming Mode)?"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                info "[DRY-RUN] would run: curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh"
            else
                info "Installing Decky Loader..."
                curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh
                success "Decky Loader installed."
            fi
        fi
    fi

    # --- SimpleDeckyTDP ---
    if [[ -d "$HOME/homebrew/plugins/SimpleDeckyTDP" ]]; then
        success "SimpleDeckyTDP already installed."
    else
        if ask_yn "Install SimpleDeckyTDP plugin (TDP control)?"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                info "[DRY-RUN] would install 7zip and run SimpleDeckyTDP install script"
            else
                run_sudo pacman -S --needed --noconfirm 7zip
                info "Installing SimpleDeckyTDP..."
                curl -L https://github.com/aarron-lee/SimpleDeckyTDP/raw/main/install.sh | sh
                success "SimpleDeckyTDP installed."
            fi
        fi
    fi

    # --- Heroic Games Launcher ---
    if is_pkg_installed heroic-games-launcher-bin; then
        success "Heroic Games Launcher already installed."
    else
        if ask_yn "Install Heroic Games Launcher (Epic/GOG/Amazon)?"; then
            run_cmd yay -S --needed --noconfirm heroic-games-launcher-bin
            success "Heroic Games Launcher installed."
        fi
    fi

    # --- Cleanup ---
    if [[ -d "$TMP_DIR" ]]; then
        info "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
    fi

    success "Steam Gamescope setup complete."
}
