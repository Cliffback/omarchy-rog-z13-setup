#!/bin/bash
# Phase 26: Lid close hibernates
# Closing the lid suspends, then hibernates after 15 minutes (or earlier below
# 5% battery), on battery and on AC. s2idle drained ~8-9%/h on this machine, and
# UPower is frozen during suspend, so a plain closed-lid suspend could run the
# battery flat and lose the session. A manual Suspend from the menu stays a
# plain suspend. While awake, UPower hibernates at 5% instead of its default
# Auto action at 2%.
# Hooks need no change: mt7925-hibernate and keyboard-backlight-sleep branch on
# SYSTEMD_SLEEP_ACTION, which suspend-then-hibernate sets per step. Phase 24's
# z13-llm-unload.service is wanted by suspend-then-hibernate.target.
# See docs/hibernation.md "Lid close and low battery".

LID_LOGIND_SRC="$SCRIPT_DIR/templates/systemd/logind.conf.d/30-z13-lid-hibernate.conf"
LID_LOGIND_DEST="/etc/systemd/logind.conf.d/30-z13-lid-hibernate.conf"
LID_DELAY_SRC="$SCRIPT_DIR/templates/systemd/sleep.conf.d/z13-hibernate-delay.conf"
LID_DELAY_DEST="/etc/systemd/sleep.conf.d/z13-hibernate-delay.conf"
LID_UPOWER_SRC="$SCRIPT_DIR/templates/UPower/70-z13-critical-hibernate.conf"
LID_UPOWER_DEST="/etc/UPower/UPower.conf.d/70-z13-critical-hibernate.conf"

phase26_check() {
    cmp -s "$LID_LOGIND_SRC" "$LID_LOGIND_DEST" \
        && cmp -s "$LID_DELAY_SRC" "$LID_DELAY_DEST" \
        && cmp -s "$LID_UPOWER_SRC" "$LID_UPOWER_DEST"
}

phase26_run() {
    info "Lid close: suspend, then hibernate after 15 min (battery and AC)."
    run_sudo install -Dm644 "$LID_LOGIND_SRC" "$LID_LOGIND_DEST"
    run_sudo install -Dm644 "$LID_DELAY_SRC" "$LID_DELAY_DEST"
    # SIGHUP reloads logind.conf; restarting logind would end the session.
    run_sudo systemctl kill -s HUP systemd-logind
    success "Installed $LID_LOGIND_DEST and $LID_DELAY_DEST"

    info "Critical battery (5%) while awake: hibernate."
    run_sudo install -Dm644 "$LID_UPOWER_SRC" "$LID_UPOWER_DEST"
    run_sudo systemctl restart upower
    success "Installed $LID_UPOWER_DEST"

    info "Check: busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch"
    info "  and: busctl call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetCriticalAction"
    info "After a lid close: journalctl -b -u systemd-suspend-then-hibernate.service"
}
