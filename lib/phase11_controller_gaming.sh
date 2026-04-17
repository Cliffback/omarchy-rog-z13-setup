#!/bin/bash
# Phase 11: Controller Gaming Trigger (optional)
# Monitors any connected gamepad for BTN_MODE + BTN_START combo press
# and launches gaming mode via /usr/local/bin/switch-to-gaming.
# Uses python-evdev. Only runs under Hyprland (not gamescope).

CTRL_TRIGGER_SCRIPT="/usr/local/bin/controller-gaming-trigger"
CTRL_TRIGGER_SERVICE="controller-gaming-trigger.service"
CTRL_TRIGGER_SERVICE_DIR="$HOME/.config/systemd/user"
CTRL_TRIGGER_SERVICE_PATH="$CTRL_TRIGGER_SERVICE_DIR/$CTRL_TRIGGER_SERVICE"

phase11_check() {
    [[ -f "$CTRL_TRIGGER_SCRIPT" ]] \
        && systemctl --user is-enabled "$CTRL_TRIGGER_SERVICE" &>/dev/null
}

phase11_run() {
    info "Setting up controller gaming mode trigger..."
    info "Pressing the Guide/PS button + Start simultaneously on any gamepad"
    info "will switch to Gamescope gaming mode (runs /usr/local/bin/switch-to-gaming)."
    info "Only active in Hyprland — does not run inside Gamescope sessions."

    # Ensure python-evdev is installed
    if ! python3 -c "import evdev" &>/dev/null; then
        info "Installing python-evdev..."
        run_sudo pacman -S --noconfirm python-evdev
    else
        info "python-evdev already installed."
    fi

    # Ensure user is in the input group for /dev/input/* access
    if ! groups "$USER" | grep -qw input; then
        info "Adding $USER to input group..."
        run_sudo usermod -aG input "$USER"
        warn "You may need to log out and back in for input group membership to take effect."
    fi

    # Deploy the trigger script
    info "Installing controller trigger script..."
    run_sudo cp "$SCRIPT_DIR/templates/controller-gaming-trigger.py" "$CTRL_TRIGGER_SCRIPT"
    run_sudo chmod +x "$CTRL_TRIGGER_SCRIPT"
    success "Trigger script installed at $CTRL_TRIGGER_SCRIPT"

    # Deploy the systemd user service
    info "Installing systemd user service..."
    run_cmd mkdir -p "$CTRL_TRIGGER_SERVICE_DIR"
    run_cmd cp "$SCRIPT_DIR/templates/controller-gaming-trigger.service" "$CTRL_TRIGGER_SERVICE_PATH"

    # Enable and start the service
    info "Enabling and starting $CTRL_TRIGGER_SERVICE..."
    run_cmd systemctl --user daemon-reload
    run_cmd systemctl --user enable --now "$CTRL_TRIGGER_SERVICE"
    success "Controller gaming trigger service is active."
}
