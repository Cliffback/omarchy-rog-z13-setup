#!/bin/bash
# Phase 12: Audio Sink Routing (priority-based automatic switching)
# Configures WirePlumber to prefer Bluetooth > HDMI > Internal speakers.
# Disables saved default restoration so priority-based switching always wins.
# Keeps outputs that cannot detect a plugged device (Radeon Pro Audio PCMs,
# the CalDigit dock's USB output) below the internal speakers.

AUDIO_ROUTING_CONF="$HOME/.config/wireplumber/wireplumber.conf.d/audio-sink-priorities.conf"

phase12_check() {
    # Content check, not just existence: installs that predate the pro-output
    # and dock rules already have the file and would otherwise never update.
    [[ -f "$AUDIO_ROUTING_CONF" ]] \
        && file_contains "$AUDIO_ROUTING_CONF" "pro-output"
}

phase12_run() {
    info "Configuring audio sink priority routing..."
    mkdir -p ~/.config/wireplumber/wireplumber.conf.d
    cat > "$AUDIO_ROUTING_CONF" << 'EOF'
## Audio sink priority routing.
## Bluetooth > HDMI > Internal speakers.
## Disables saved default restoration so priority always wins.
##
## Two outputs cannot report whether anything is plugged into them, so they are
## kept below the internal speakers instead of above them:
##
##  - Radeon HDMI "Pro Audio" PCMs (pro-output-*) expose no ports, so
##    WirePlumber counts them as available even with no cable attached and the
##    card profile set to "off". Their default priority (1100-1200) beats the
##    internal analog sink (1009), so one of them becomes the default and every
##    stream plays into a dead HDMI jack after the monitor is unplugged.
##  - The CalDigit dock's USB analog output has no jack detection either
##    ("availability unknown"), so it wins over the internal speakers while
##    nothing is plugged into it.
##
## Real HDMI (hdmi-stereo, 1500) does track the jack and still wins while a
## display is connected; real USB speakers (e.g. the KEF LSX, 1109) still win
## too. Select a dock output or a Pro output by hand when you do want it.

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
  {
    matches = [
      {
        node.name = "~alsa_output.*pro-output.*"
      }
    ]
    actions = {
      update-props = {
        priority.session = 100
      }
    }
  }
  {
    matches = [
      {
        node.name = "~alsa_output.*usb-CalDigit.*"
      }
    ]
    actions = {
      update-props = {
        priority.session = 900
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
