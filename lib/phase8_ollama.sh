#!/bin/bash
# Phase 8: Ollama GPU Setup (optional)

OLLAMA_OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_OVERRIDE="$OLLAMA_OVERRIDE_DIR/override.conf"

phase8_check() {
    is_pkg_installed ollama-vulkan \
        && [[ -f "$OLLAMA_OVERRIDE" ]] \
        && is_service_enabled ollama
}

phase8_run() {
    info "Setting up Ollama with GPU acceleration (Vulkan)..."

    # BIOS reminder
    echo ""
    warn "For optimal performance with large models, set iGPU memory to 96GB in BIOS."
    echo ""

    # Install ollama-vulkan
    if is_pkg_installed ollama-vulkan; then
        success "ollama-vulkan already installed."
    else
        info "Installing ollama-vulkan..."
        run_sudo pacman -S --noconfirm ollama-vulkan
    fi

    # Ask about network access
    local ollama_host="127.0.0.1:11434"
    if ask_yn "Allow network access to Ollama? (Required for access from other devices)"; then
        ollama_host="0.0.0.0:11434"
    fi

    # Create systemd override
    if [[ -f "$OLLAMA_OVERRIDE" ]]; then
        success "Systemd override already exists."
    else
        info "Creating systemd service override..."
        run_sudo mkdir -p "$OLLAMA_OVERRIDE_DIR"

        local override_content="[Service]
Environment=\"OLLAMA_VULKAN=1\"
Environment=\"OLLAMA_FLASH_ATTENTION=1\"
Environment=\"OLLAMA_HOST=$ollama_host\"
Environment=\"OLLAMA_CONTEXT_LENGTH=262144\"
Environment=\"OLLAMA_KEEP_ALIVE=24h\"
Environment=\"OLLAMA_MAX_LOADED_MODELS=3\"
"
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would write to $OLLAMA_OVERRIDE:"
            echo "$override_content"
        else
            echo "$override_content" | sudo tee "$OLLAMA_OVERRIDE" >/dev/null
        fi
        success "Systemd override created."
    fi

    # Reload and enable service
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now ollama
    success "Ollama service enabled and started."

    # Optional: install nvtop for monitoring
    if ! is_pkg_installed nvtop; then
        if ask_yn "Install nvtop for GPU monitoring?"; then
            run_sudo pacman -S --noconfirm nvtop
            success "nvtop installed."
        fi
    fi

    # Verification instructions
    echo ""
    info "To verify GPU acceleration is working:"
    info "  1. Run: ollama run <model>  (e.g., ollama run llama3)"
    info "  2. In another terminal: ollama ps"
    info "  3. Check the PROCESSOR column shows 'GPU' not 'CPU'"
    info "  4. Optional: run 'nvtop' to monitor GPU usage"
}
