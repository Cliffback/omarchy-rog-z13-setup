#!/bin/bash
# z13-audio-hotplug — hand audio back to the internal speakers when the last
# external display is disconnected. Deployed by Phase 12.
#
# Why this exists
# ---------------
# HDMI output is selected by hand: Phase 12 keeps HDMI below the internal
# speakers so a phantom HDMI sink can never steal the default on its own. But
# once HDMI *has* been selected, unplugging the monitor leaves two problems:
#
#   * the default sink still points at the HDMI node, which now has no
#     receiver, so every stream keeps "playing" into silence; and
#   * the HDMI card's ACP route can stay cached as available (with the old
#     product name) even though the HDA jack reads "off" and the DRM connector
#     is disconnected, so the leaked hdmi-stereo node stays selectable.
#
# This watcher samples the DRM connector states. When the last external
# connector disappears it forces any HDMI card profile to "off", which
# destroys the node and lets WirePlumber re-elect the internal sink. If a
# leaked node survives that (the card already reports "off" but the node is
# still there), it restarts WirePlumber once so the jack is re-probed.
#
# It only acts on the transition to "no external display", so manual HDMI
# selection is never touched while a display is connected. A plug-in is left
# to the ACP auto-profile rule installed by Phase 3, which re-activates the
# card's HDMI profile when the jack goes live.
#
# Logs one line per action: journalctl -b -t z13-audio-hotplug

set -u

INTERVAL=2
HDMI_SINK_RE='\.(hdmi|pro-output)-'
INTERNAL_SINK_RE='^alsa_output\.pci-.*\.analog-stereo$'
LOG_TAG=z13-audio-hotplug

log() { logger -t "$LOG_TAG" -- "$*"; }

has_command() { command -v "$1" >/dev/null 2>&1; }

# Names of external DRM connectors that are currently connected. eDP/LVDS are
# the internal panel; Writeback/Virtual are not real outputs.
external_displays() {
    local f name

    for f in /sys/class/drm/card*-*/status; do
        [[ -r $f ]] || continue
        name=${f#/sys/class/drm/}
        name=${name%/status}
        name=${name#card*-}
        case $name in
            eDP-*|LVDS-*|Writeback-*|*Virtual*) continue ;;
        esac
        [[ $(<"$f") == connected ]] && printf '%s\n' "$name"
    done
}

# Active profile of a card, as reported by PipeWire.
active_profile() {
    local card=$1

    pactl list cards 2>/dev/null | awk -v c="Name: $card" '
        index ($0, c) > 0 { found = 1 }
        found && /Active Profile:/ {
            sub (/^[[:space:]]*Active Profile:[[:space:]]*/, "")
            print
            exit
        }
    '
}

internal_sink() {
    pactl list short sinks 2>/dev/null \
        | awk '{ print $2 }' \
        | grep -E "$INTERNAL_SINK_RE" \
        | head -n 1
}

# Force the HDMI card off and make sure the default sink is not a dead HDMI
# node. Idempotent and quiet when there is nothing to do.
revert_to_internal() {
    local card profile sinks cur internal

    while read -r card; do
        profile=$(active_profile "$card")
        [[ -n $profile && $profile != off && $profile == *hdmi* ]] || continue
        log "no external display: turning $card profile off (was $profile)"
        pactl set-card-profile "$card" off >/dev/null 2>&1 || true
    done < <(pactl list short cards 2>/dev/null | awk '{ print $2 }')

    sleep 1

    sinks=$(pactl list short sinks 2>/dev/null | awk '{ print $2 }')
    if grep -qE "$HDMI_SINK_RE" <<<"$sinks"; then
        # A node outlived its card profile: only a re-probe clears it.
        log "leaked HDMI sink survived profile off; restarting wireplumber"
        systemctl --user restart wireplumber >/dev/null 2>&1 || true
        sleep 2
    fi

    cur=$(pactl get-default-sink 2>/dev/null || true)
    if [[ $cur =~ $HDMI_SINK_RE ]]; then
        internal=$(internal_sink)
        if [[ -n $internal ]]; then
            log "default was $cur; switching to $internal"
            pactl set-default-sink "$internal" >/dev/null 2>&1 || true
        fi
    fi
}

if ! has_command pactl || ! has_command systemctl; then
    log "pactl/systemctl missing; exiting"
    exit 1
fi

prev=__start__
while :; do
    ext=$(external_displays | paste -sd, -)
    if [[ $ext != "$prev" ]]; then
        if [[ -z $ext ]]; then
            revert_to_internal
        else
            log "external display connected: ${ext//,/, }"
        fi
        prev=$ext
    fi
    sleep "$INTERVAL"
done
