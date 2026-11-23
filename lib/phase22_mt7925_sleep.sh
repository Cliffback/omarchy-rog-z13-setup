#!/bin/bash
# Phase 22: MT7925 Wi-Fi hibernate hook
# The MediaTek MT7925 (mt7925e) times out on restore from hibernation
# ("Message 00020015 (seq N) timeout", then wiphy_resume returns -110) and
# Wi-Fi stays dead until the module is reloaded. A systemd-sleep hook unloads
# the driver before hibernating and loads it again afterwards.
#
# systemd 262 reads hooks only from /usr/lib/systemd/system-sleep/; one in
# /etc/systemd/system-sleep/ never runs. `options mt7925e disable_aspm=1` was
# tested and does not help. See docs/hibernation.md.

MT7925_HOOK_SRC="$SCRIPT_DIR/templates/mt7925-hibernate"
MT7925_HOOK_DEST="/usr/lib/systemd/system-sleep/mt7925-hibernate"
MT7925_HOOK_STALE="/etc/systemd/system-sleep/mt7925-hibernate"

mt7925_present() {
    # PCI ID 14c3:7925 (MediaTek MT7925). Fall back to the loaded module.
    [[ -n "$(lspci -d 14c3:7925 2>/dev/null)" || -d /sys/module/mt7925e ]]
}

phase22_check() {
    if ! mt7925_present; then
        info "No MT7925 Wi-Fi adapter found; nothing to do."
        return 0
    fi
    cmp -s "$MT7925_HOOK_SRC" "$MT7925_HOOK_DEST" && [[ ! -e "$MT7925_HOOK_STALE" ]]
}

phase22_run() {
    info "Installing the MT7925 hibernate hook to $MT7925_HOOK_DEST..."
    run_sudo install -Dm755 "$MT7925_HOOK_SRC" "$MT7925_HOOK_DEST"
    success "Installed $MT7925_HOOK_DEST"

    if [[ -e "$MT7925_HOOK_STALE" ]]; then
        info "Removing $MT7925_HOOK_STALE (systemd 262 ignores /etc/systemd/system-sleep/)."
        run_sudo rm -f "$MT7925_HOOK_STALE"
        run_sudo rmdir --ignore-fail-on-non-empty /etc/systemd/system-sleep
    fi

    info "Verify on the next hibernate: journalctl -b -t mt7925-sleep"
    info "  expect 'pre hibernate: loaded=1', 'after pre: loaded=0', 'post hibernate: loaded=1'"
    info "  and no 'Message 00020015' / 'wiphy_resume ... -110' in journalctl -k -b"
}
