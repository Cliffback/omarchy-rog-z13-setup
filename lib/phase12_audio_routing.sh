#!/bin/bash
# Phase 12: Audio Sink Routing (priority-based automatic switching)
# Disables saved default restoration so priority-based switching always wins.
# Bluetooth and USB speakers outrank the internal speakers; HDMI and outputs
# that cannot report a plugged device stay below them. HDMI is selected by
# hand, and the z13-audio-hotplug user service hands audio back to the
# internal speakers when the last external display is disconnected.

AUDIO_ROUTING_CONF="$HOME/.config/wireplumber/wireplumber.conf.d/audio-sink-priorities.conf"
AUDIO_HOTPLUG_SCRIPT="$HOME/.local/bin/z13-audio-hotplug"
AUDIO_HOTPLUG_UNIT="z13-audio-hotplug.service"
AUDIO_HOTPLUG_UNIT_DIR="$HOME/.config/systemd/user"

phase12_check() {
    # Content check, not just existence: machines provisioned with the older
    # rules already have the file and would otherwise never pick up changes.
    [[ -f "$AUDIO_ROUTING_CONF" ]] \
        && file_contains "$AUDIO_ROUTING_CONF" "z13-audio-routing v3" \
        && [[ -x "$AUDIO_HOTPLUG_SCRIPT" ]] \
        && systemctl --user is-enabled "$AUDIO_HOTPLUG_UNIT" &>/dev/null
}

phase12_run() {
    info "Configuring audio sink priority routing..."
    mkdir -p ~/.config/wireplumber/wireplumber.conf.d
    cat > "$AUDIO_ROUTING_CONF" << 'EOF'
## Audio sink priority routing.
## Bluetooth and USB speakers outrank the internal speakers; everything whose
## presence cannot be trusted stays below them. Disables saved default
## restoration so priority always wins.
##
## Markers: z13-audio-routing v3
##
## Below the internal analog sink (1009):
##
##  - HDMI (950). WirePlumber normally skips a node whose device route is
##    unavailable, but the ACP route on this machine goes stale: after the
##    monitor is unplugged the card can still report its HDMI route as
##    available, with the monitor's product name, even though the HDA jack
##    reads "off" and the DRM connector is disconnected. The HDMI node then
##    keeps winning the default and every stream plays into a dead jack. That
##    state has survived a suspend/resume, so HDMI is opt-in here: pick the
##    display output in the sound panel when you want monitor audio. The
##    z13-audio-hotplug user service watches the DRM connectors and forces the
##    HDMI card off when the last external display disappears, which clears
##    the leaked node (restarting WirePlumber to re-probe the jack if a node
##    survives) and returns the default to the internal speakers.
##  - CalDigit dock USB analog (900): no jack detection ("availability
##    unknown"), so it wins over the internal speakers while nothing is
##    plugged into it.
##  - Radeon HDMI Pro Audio PCMs (pro-output-*, 100): expose no ports at all,
##    so they count as available even with the card profile set to "off".
##
## Above it: Bluetooth (2000) and real USB speakers such as the KEF LSX
## (1109, device default, left untouched).

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
        priority.session = 950
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

    # HDMI is picked by hand, so make sure unplugging the display hands audio
    # back to the internal speakers instead of leaving it on a dead jack.
    local hotplug_script_src="$SCRIPT_DIR/templates/z13-audio-hotplug.sh"
    local hotplug_unit_src="$SCRIPT_DIR/templates/z13-audio-hotplug.service"
    if [[ -f $hotplug_script_src && -f $hotplug_unit_src ]]; then
        if [[ ! -x "$AUDIO_HOTPLUG_SCRIPT" ]] || ! cmp -s "$hotplug_script_src" "$AUDIO_HOTPLUG_SCRIPT"; then
            info "Installing HDMI unplug watcher..."
            run_cmd mkdir -p "$HOME/.local/bin"
            run_cmd install -m 0755 "$hotplug_script_src" "$AUDIO_HOTPLUG_SCRIPT"
        fi
        run_cmd mkdir -p "$AUDIO_HOTPLUG_UNIT_DIR"
        run_cmd install -m 0644 "$hotplug_unit_src" "$AUDIO_HOTPLUG_UNIT_DIR/$AUDIO_HOTPLUG_UNIT"
        run_cmd systemctl --user daemon-reload
        run_cmd systemctl --user enable --now "$AUDIO_HOTPLUG_UNIT"
        success "HDMI unplug watcher active."
    else
        warn "HDMI unplug watcher template missing; audio stays on HDMI after unplug."
    fi

    success "Audio sink routing configured (Bluetooth/USB > internal > HDMI)."
}
