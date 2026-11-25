#!/bin/bash
# Phase 9: Audio Amplifier Gain (CS35L41 bincfg)
# Increases speaker amplifier gain from 15.5dB (default) to 19.5dB for louder output.
# Reference: https://dev.to/ankk98/rog-flow-z13-2025-linux-audio-quality-investigation-3ggk
#
# linux-firmware-cirrus owns the two gain symlinks and resets them to 15.5 dB on
# every update (seen 2026-10-23), so this phase also installs a pacman hook that
# runs /usr/local/bin/z13-cs35l41-gain after each install/upgrade of it.

FIRMWARE_DIR="/lib/firmware/cirrus"
BINCFG_TARGET="cs35l41/bincfgs/cs35l41-dsp1-19_5dB.bincfg.zst"
BINCFG_L="cs35l41-dsp1-spk-prot-10431fb3-l0.bincfg.zst"
BINCFG_R="cs35l41-dsp1-spk-prot-10431fb3-r0.bincfg.zst"
GAIN_SCRIPT_SRC="$SCRIPT_DIR/templates/z13-cs35l41-gain"
GAIN_SCRIPT_DEST="/usr/local/bin/z13-cs35l41-gain"
GAIN_HOOK_SRC="$SCRIPT_DIR/templates/pacman-hooks/z13-cs35l41-gain.hook"
GAIN_HOOK_DEST="/etc/pacman.d/hooks/z13-cs35l41-gain.hook"

phase9_check() {
  [[ -L "$FIRMWARE_DIR/$BINCFG_L" ]] \
    && [[ -L "$FIRMWARE_DIR/$BINCFG_R" ]] \
    && [[ "$(readlink "$FIRMWARE_DIR/$BINCFG_L")" == "$BINCFG_TARGET" ]] \
    && [[ "$(readlink "$FIRMWARE_DIR/$BINCFG_R")" == "$BINCFG_TARGET" ]] \
    && cmp -s "$GAIN_SCRIPT_SRC" "$GAIN_SCRIPT_DEST" \
    && cmp -s "$GAIN_HOOK_SRC" "$GAIN_HOOK_DEST"
}

phase9_run() {
  info "Setting CS35L41 amplifier gain to 19.5dB..."

  if [[ ! -f "$FIRMWARE_DIR/$BINCFG_TARGET" ]]; then
    error "Gain config not found: $FIRMWARE_DIR/$BINCFG_TARGET"
    error "Ensure linux-firmware is installed and up to date."
    return 1
  fi

  run_sudo install -Dm755 "$GAIN_SCRIPT_SRC" "$GAIN_SCRIPT_DEST"
  run_sudo install -Dm644 "$GAIN_HOOK_SRC" "$GAIN_HOOK_DEST"
  success "Installed pacman hook $GAIN_HOOK_DEST (keeps 19.5dB across linux-firmware-cirrus updates)"

  local before_l before_r
  before_l=$(readlink "$FIRMWARE_DIR/$BINCFG_L" 2>/dev/null)
  before_r=$(readlink "$FIRMWARE_DIR/$BINCFG_R" 2>/dev/null)
  run_sudo "$GAIN_SCRIPT_DEST"

  if [[ "$before_l" != "$BINCFG_TARGET" || "$before_r" != "$BINCFG_TARGET" ]]; then
    NEEDS_REBOOT=1
    success "Amplifier gain set to 19.5dB (reboot required to take effect)."
  else
    success "Amplifier gain already 19.5dB."
  fi
}
