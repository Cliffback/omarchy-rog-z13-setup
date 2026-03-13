#!/bin/bash
# Phase 9: Audio EQ (EasyEffects with Z13-optimized presets)
# Presets sourced from: https://github.com/Naomarik/Z13-StrixHalo-Omarchy

EASYEFFECTS_PRESET_REPO="https://github.com/Naomarik/Z13-StrixHalo-Omarchy"
EASYEFFECTS_CONFIG="$HOME/.config/easyeffects/db/easyeffectsrc"
AUTOLOAD_DIR="$HOME/.local/share/easyeffects/autoload/output"
SPEAKERS_AUTOLOAD="$AUTOLOAD_DIR/alsa_output.pci-0000_c4_00.6.analog-stereo:Speakers.json"

phase9_check() {
  is_pkg_installed easyeffects \
    && [[ -f ~/.local/share/easyeffects/output/IRZ13\ Flow.json ]] \
    && [[ -f ~/.local/share/easyeffects/output/Perfect\ EQ.json ]] \
    && [[ -f ~/.local/share/easyeffects/irs/ir1.irs ]] \
    && [[ -f ~/.config/autostart/easyeffects-service.desktop ]] \
    && [[ -f "$SPEAKERS_AUTOLOAD" ]] \
    && grep -q "outputAutoloadingUsesFallback=true" "$EASYEFFECTS_CONFIG" 2>/dev/null
}

phase9_run() {
  # Install EasyEffects
  if ! is_pkg_installed easyeffects; then
    info "Installing EasyEffects..."
    run_sudo pacman -S --noconfirm easyeffects
  else
    success "EasyEffects already installed."
  fi

  # Create directories
  run_cmd mkdir -p ~/.local/share/easyeffects/{input,output,irs,autoload/output}
  run_cmd mkdir -p ~/.config/autostart
  run_cmd mkdir -p ~/.config/easyeffects/db

  # Clone preset repo and copy files
  info "Downloading Z13 presets from Naomarik/Z13-StrixHalo-Omarchy..."
  local tmpdir
  tmpdir=$(mktemp -d)
  run_cmd git clone --depth 1 "$EASYEFFECTS_PRESET_REPO" "$tmpdir/z13-presets"

  # Copy both presets and impulse response
  run_cmd cp "$tmpdir/z13-presets/easyeffects/output/IRZ13 Flow.json" ~/.local/share/easyeffects/output/
  run_cmd cp "$tmpdir/z13-presets/easyeffects/output/Perfect EQ.json" ~/.local/share/easyeffects/output/
  run_cmd cp "$tmpdir/z13-presets/easyeffects/irs/ir1.irs" ~/.local/share/easyeffects/irs/
  rm -rf "$tmpdir"
  success "Z13 presets installed (IRZ13 Flow + Perfect EQ)."

  # Create autostart desktop entry for service mode
  info "Configuring EasyEffects autostart..."
  cat > ~/.config/autostart/easyeffects-service.desktop << 'EOF'
[Desktop Entry]
Name=Easy Effects (Service)
Exec=easyeffects --service-mode
Type=Application
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
EOF
  success "EasyEffects autostart configured."

  # Configure autoload for internal speakers (route-based, not device-based)
  # Headphones and other devices will use the fallback preset (Perfect EQ)
  info "Configuring speaker preset autoloading..."
  cat > "$SPEAKERS_AUTOLOAD" << 'EOF'
{
    "device": "alsa_output.pci-0000_c4_00.6.analog-stereo",
    "device-description": "Ryzen HD Audio Controller Analog Stereo",
    "device-profile": "Speakers",
    "preset-name": "IRZ13 Flow"
}
EOF
  success "Speaker route autoload configured (IRZ13 Flow)."

  # Configure fallback preset for headphones and other devices
  info "Configuring fallback preset (Perfect EQ)..."
  if [[ -f "$EASYEFFECTS_CONFIG" ]]; then
    # Update existing config - add fallback settings to [Window] section if not present
    if ! grep -q "outputAutoloadingUsesFallback" "$EASYEFFECTS_CONFIG"; then
      sed -i '/^\[Window\]/a outputAutoloadingFallbackPreset=Perfect EQ\noutputAutoloadingUsesFallback=true' "$EASYEFFECTS_CONFIG"
    fi
  else
    # Create minimal config with fallback settings
    cat > "$EASYEFFECTS_CONFIG" << 'EOF'
[Presets]
lastLoadedOutputPreset=IRZ13 Flow

[StreamOutputs]
outputDevice=alsa_output.pci-0000_c4_00.6.analog-stereo

[Window]
outputAutoloadingFallbackPreset=Perfect EQ
outputAutoloadingUsesFallback=true
EOF
  fi
  success "Fallback preset configured (Perfect EQ for headphones/other devices)."

  # Load the preset now
  info "Loading IRZ13 Flow preset for current session..."
  if pgrep -x easyeffects > /dev/null; then
    run_cmd easyeffects -l "IRZ13 Flow"
  else
    run_cmd easyeffects --service-mode &
    sleep 2
    run_cmd easyeffects -l "IRZ13 Flow"
  fi
  success "Audio EQ setup complete."
}
