#!/bin/bash
# Phase 24: Unload local LLMs before hibernate
# The GPU's memory on Strix Halo is unswappable system RAM, and hibernation
# needs free RAM to copy the in-use pages into. A model loaded in llama-swap or
# Ollama (tens of GB) makes `systemctl hibernate` fail with "Cannot allocate
# memory". z13-llm-unload.service runs before the hibernate and unloads them.
#
# Not a system-sleep hook: those run after user.slice is frozen, and
# llama-swap runs as a user service. suspend-then-hibernate is not covered
# (its hibernate step does not pass through hibernate.target); this machine
# only hibernates on request.

LLM_UNLOAD_SCRIPT_SRC="$SCRIPT_DIR/templates/z13-llm-unload"
LLM_UNLOAD_SCRIPT_DEST="/usr/local/bin/z13-llm-unload"
LLM_UNLOAD_UNIT_SRC="$SCRIPT_DIR/templates/systemd/system/z13-llm-unload.service"
LLM_UNLOAD_UNIT_DEST="/etc/systemd/system/z13-llm-unload.service"

phase24_check() {
    cmp -s "$LLM_UNLOAD_SCRIPT_SRC" "$LLM_UNLOAD_SCRIPT_DEST" \
        && cmp -s "$LLM_UNLOAD_UNIT_SRC" "$LLM_UNLOAD_UNIT_DEST" \
        && is_service_enabled z13-llm-unload
}

phase24_run() {
    local dep
    for dep in curl jq; do
        if ! has_command "$dep"; then
            info "Installing $dep..."
            run_sudo pacman -S --needed --noconfirm "$dep"
        fi
    done

    info "Installing $LLM_UNLOAD_SCRIPT_DEST and $LLM_UNLOAD_UNIT_DEST..."
    run_sudo install -Dm755 "$LLM_UNLOAD_SCRIPT_SRC" "$LLM_UNLOAD_SCRIPT_DEST"
    run_sudo install -Dm644 "$LLM_UNLOAD_UNIT_SRC" "$LLM_UNLOAD_UNIT_DEST"
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable z13-llm-unload.service
    success "z13-llm-unload.service enabled for hibernate and hybrid-sleep"

    info "Endpoints default to llama-swap http://127.0.0.1:8000 and Ollama http://127.0.0.1:11434;"
    info "  override with LLAMA_SWAP_URL= / OLLAMA_URL= in /etc/default/z13-llm-unload."
    info "Test without hibernating: sudo systemctl start z13-llm-unload; journalctl -b -t z13-llm-unload"
}
