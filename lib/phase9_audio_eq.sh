#!/bin/bash
# Phase 9: Audio Amplifier Gain (CS35L41 bincfg)
# Increases speaker amplifier gain from 15.5dB (default) to 19.5dB for louder output.
# Reference: https://dev.to/ankk98/rog-flow-z13-2025-linux-audio-quality-investigation-3ggk

FIRMWARE_DIR="/lib/firmware/cirrus"
BINCFG_TARGET="cs35l41/bincfgs/cs35l41-dsp1-19_5dB.bincfg.zst"
BINCFG_L="cs35l41-dsp1-spk-prot-10431fb3-l0.bincfg.zst"
BINCFG_R="cs35l41-dsp1-spk-prot-10431fb3-r0.bincfg.zst"

phase9_check() {
  [[ -L "$FIRMWARE_DIR/$BINCFG_L" ]] \
    && [[ -L "$FIRMWARE_DIR/$BINCFG_R" ]] \
    && [[ "$(readlink "$FIRMWARE_DIR/$BINCFG_L")" == "$BINCFG_TARGET" ]] \
    && [[ "$(readlink "$FIRMWARE_DIR/$BINCFG_R")" == "$BINCFG_TARGET" ]]
}

phase9_run() {
  info "Setting CS35L41 amplifier gain to 19.5dB..."

  if [[ ! -f "$FIRMWARE_DIR/$BINCFG_TARGET" ]]; then
    error "Gain config not found: $FIRMWARE_DIR/$BINCFG_TARGET"
    error "Ensure linux-firmware is installed and up to date."
    return 1
  fi

  run_sudo ln -sf "$BINCFG_TARGET" "$FIRMWARE_DIR/$BINCFG_L"
  run_sudo ln -sf "$BINCFG_TARGET" "$FIRMWARE_DIR/$BINCFG_R"

  NEEDS_REBOOT=1
  success "Amplifier gain set to 19.5dB (reboot required to take effect)."
}
