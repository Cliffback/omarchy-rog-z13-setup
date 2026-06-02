#!/bin/bash
# Phase 17: Unreal Engine 5 (optional)
# Installs Unreal Engine 5 binary releases with HiDPI scaling fix,
# launcher aliases, desktop integration, and bidirectional Neovim support.
#
# Requires manually downloading a Linux binary zip from Epic first:
#   https://www.unrealengine.com/linux
#
# This phase delegates to the standalone scripts/install-unreal-engine.sh
# which handles extraction, permissions, icons, MIME types, and launcher creation.
# After UE is installed, optionally run scripts/setup-ue-neovim.sh to configure
# Neovim/LazyVim for C++ development with bidirectional file opening.

INSTALL_BASE="$HOME/UnrealEngine"

phase17_check() {
    # Check if any UE version is installed (look for UnrealEditor binary)
    if [[ -d "$INSTALL_BASE" ]]; then
        for editor in "$INSTALL_BASE"/*/Engine/Binaries/Linux/UnrealEditor; do
            [[ -f "$editor" ]] && return 0
        done
    fi
    return 1
}

phase17_run() {
    local installer="$SCRIPT_DIR/scripts/install-unreal-engine.sh"

    if [[ ! -f "$installer" ]]; then
        error "Installer not found: $installer"
        return 0
    fi

    # Pass --dry-run through if active
    local args=()
    [[ $DRY_RUN -eq 1 ]] && args+=("--dry-run")

    info "Launching Unreal Engine installer..."
    info "You must have downloaded a Linux_Unreal_Engine_*.zip to ~/Downloads/ first."
    info "  https://www.unrealengine.com/linux (requires Epic login)"
    echo ""

    run_cmd bash "$installer" "${args[@]}"

    # After UE install, offer to set up Neovim integration
    if phase17_check; then
        echo ""
        if ask_yn "Configure Neovim integration for Unreal Engine C++ development?"; then
            local nvim_setup="$SCRIPT_DIR/scripts/setup-ue-neovim.sh"
            if [[ -f "$nvim_setup" ]]; then
                run_cmd bash "$nvim_setup"
            else
                warn "Neovim setup script not found: $nvim_setup"
            fi
        fi
    fi
}
