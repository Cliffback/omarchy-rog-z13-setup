#!/bin/bash
# Phase 8: Ollama GPU Setup (optional)

OLLAMA_OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_OVERRIDE="$OLLAMA_OVERRIDE_DIR/override.conf"
OPENWEBUI_CONTAINER="open-webui"
OPENWEBUI_PORT="8081"  # Port 8080 conflicts with Steam CEF (breaks Decky Loader)

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

    # --- Open WebUI (optional web interface for Ollama) ---
    # NOTE: Uses port 8081 instead of default 8080 to avoid conflict with
    # Steam's CEF remote debugging port (required for Decky Loader in Gaming Mode)
    if ! has_command docker; then
        warn "Docker not found. Skipping Open WebUI installation."
    elif docker ps -a --format '{{.Names}}' | grep -q "^${OPENWEBUI_CONTAINER}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${OPENWEBUI_CONTAINER}$"; then
            success "Open WebUI already running on port $OPENWEBUI_PORT."
        else
            info "Open WebUI container exists but is not running."
            if ask_yn "Start Open WebUI container?"; then
                run_cmd docker start "$OPENWEBUI_CONTAINER"
                success "Open WebUI started."
            fi
        fi
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would prompt to install Open WebUI (web interface for Ollama)"
    else
        if ask_yn "Install Open WebUI (web interface for Ollama)?"; then
            info "Pulling and starting Open WebUI on port $OPENWEBUI_PORT..."
            docker run -d \
                --name "$OPENWEBUI_CONTAINER" \
                --network=host \
                -e PORT="$OPENWEBUI_PORT" \
                -e OLLAMA_BASE_URL=http://localhost:11434 \
                -v open-webui:/app/backend/data \
                --restart unless-stopped \
                ghcr.io/open-webui/open-webui:main
            success "Open WebUI installed and running."
        fi
    fi

    # Verification instructions
    echo ""
    info "To verify GPU acceleration is working:"
    info "  1. Run: ollama run <model>  (e.g., ollama run llama3)"
    info "  2. In another terminal: ollama ps"
    info "  3. Check the PROCESSOR column shows 'GPU' not 'CPU'"
    info "  4. Optional: run 'nvtop' to monitor GPU usage"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${OPENWEBUI_CONTAINER}$"; then
        echo ""
        info "Open WebUI is available at: http://localhost:$OPENWEBUI_PORT"
    fi
}
