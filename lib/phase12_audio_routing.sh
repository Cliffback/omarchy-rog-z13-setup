#!/bin/bash
# Phase 12: Audio Sink Routing (priority-based automatic switching)
# Configures WirePlumber to prefer Bluetooth > HDMI > Internal speakers.
# Disables saved default restoration so priority-based switching always wins.

AUDIO_ROUTING_CONF="$HOME/.config/wireplumber/wireplumber.conf.d/audio-sink-priorities.conf"

phase12_check() {
    [[ -f "$AUDIO_ROUTING_CONF" ]]
}

phase12_run() {
    info "Configuring audio sink priority routing..."
    mkdir -p ~/.config/wireplumber/wireplumber.conf.d
    cat > "$AUDIO_ROUTING_CONF" << 'EOF'
## Audio sink priority routing.
## Bluetooth > HDMI > Internal speakers.
## Disables saved default restoration so priority always wins.

wireplumber.settings = {
  node.restore-default-targets = false
}

monitor.bluez.rules = [
  {
    matches = [
      {
        node.name = "~bluez_output.*"
      }
    ]
    actions = {
      update-props = {
        priority.session = 2000
      }
    }
  }
]

monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*hdmi*"
      }
    ]
    actions = {
      update-props = {
        priority.session = 1500
      }
    }
  }
]
EOF

    # Clear stored default node state so new priorities take effect
    rm -f ~/.local/state/wireplumber/default-nodes

    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
    success "Audio sink routing configured (Bluetooth > HDMI > Internal)."
}
