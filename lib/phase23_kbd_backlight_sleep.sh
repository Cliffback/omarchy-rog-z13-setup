#!/bin/bash
# Phase 23: Keyboard backlight across hibernate
# Omarchy's /usr/lib/systemd/system-sleep/keyboard-backlight turns the ASUS
# keyboard backlight off before hibernate (it can block S4 power-off) but
# never restores it, so the backlight is off after every resume and after a
# failed hibernate. This replaces that hook, at the same path, with one that
# saves the level, turns it off, and restores it on post.
#
# Same path on purpose: systemd-sleep runs hooks in parallel, so a separate
# hook could not reliably read the level before Omarchy's hook zeroes it, and
# systemd 262 has no /etc/systemd/system-sleep/ override directory.
# Omarchy's migration 1788662350 leaves a root-owned customised copy alone; if
# an Omarchy update reinstalls its version, this phase's check fails and a
# re-run puts ours back.

KBD_SLEEP_HOOK_SRC="$SCRIPT_DIR/templates/keyboard-backlight-sleep"
KBD_SLEEP_HOOK_DEST="/usr/lib/systemd/system-sleep/keyboard-backlight"

phase23_check() {
    cmp -s "$KBD_SLEEP_HOOK_SRC" "$KBD_SLEEP_HOOK_DEST"
}

phase23_run() {
    info "Installing the keyboard backlight sleep hook to $KBD_SLEEP_HOOK_DEST..."
    run_sudo install -Dm755 "$KBD_SLEEP_HOOK_SRC" "$KBD_SLEEP_HOOK_DEST"
    success "Installed $KBD_SLEEP_HOOK_DEST (replaces Omarchy's turn-off-only hook)"

    info "Verify on the next hibernate: journalctl -b -t kbd-backlight-sleep"
    info "  expect 'pre hibernate: asus::kbd_backlight saved=N, set 0'"
    info "  and 'post hibernate: asus::kbd_backlight restore=N now=N'"
}
