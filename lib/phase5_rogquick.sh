#!/bin/bash
# Phase 5: ROG Quick TDP Menu

ROG_QUICK="$HOME/.local/bin/rog-quick.sh"

phase5_check() {
    [[ -x "$ROG_QUICK" ]]
}

phase5_run() {
    info "Installing ROG Quick TDP menu..."
    run_cmd mkdir -p "$HOME/.local/bin"
    run_cmd cp "$SCRIPT_DIR/templates/rog-quick.sh" "$ROG_QUICK"
    run_cmd chmod +x "$ROG_QUICK"
    success "ROG Quick menu installed at $ROG_QUICK"

    # Clean up old location if present
    if [[ -f "$HOME/rog-quick.sh" ]]; then
        info "Removing old ~/rog-quick.sh..."
        run_cmd rm "$HOME/rog-quick.sh"
    fi
}
