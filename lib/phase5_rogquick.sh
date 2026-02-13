#!/bin/bash
# Phase 5: ROG Quick TDP Menu

phase5_check() {
    [[ -x "$HOME/rog-quick.sh" ]]
}

phase5_run() {
    info "Installing ROG Quick TDP menu..."
    run_cmd cp "$SCRIPT_DIR/templates/rog-quick.sh" "$HOME/rog-quick.sh"
    run_cmd chmod +x "$HOME/rog-quick.sh"
    success "ROG Quick menu installed at ~/rog-quick.sh"
}
