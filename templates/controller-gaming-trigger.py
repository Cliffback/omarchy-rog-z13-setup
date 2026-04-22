#!/usr/bin/env python3
"""
controller-gaming-trigger — Monitor any gamepad for BTN_MODE + BTN_START combo
and launch gaming mode via /usr/local/bin/switch-to-gaming.

Designed to run as a systemd user service. Only triggers when gaming mode
is not already active (checks /tmp/.gaming-session-active sentinel file).
"""

import subprocess
import sys
import time
import signal
import os

import evdev
from evdev import ecodes

SWITCH_CMD = "/usr/local/bin/switch-to-gaming"
COOLDOWN_SECONDS = 5
RESCAN_INTERVAL = 2  # seconds between scans when no device found
GAMING_SENTINEL = "/tmp/.gaming-session-active"

# BTN_MODE = 316, BTN_START = 311
REQUIRED_BUTTONS = {ecodes.BTN_MODE, ecodes.BTN_START}


def is_gaming_active():
    """Check if gaming mode is already active via sentinel file."""
    return os.path.exists(GAMING_SENTINEL)


def find_gamepad():
    """Find the first input device that has both BTN_MODE and BTN_START capabilities."""
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            # Skip virtual devices (e.g. Makima) — real gamepads have analog axes
            caps = dev.capabilities(verbose=False)
            if ecodes.EV_ABS not in caps:
                dev.close()
                continue
            key_caps = set(caps.get(ecodes.EV_KEY, []))
            if REQUIRED_BUTTONS.issubset(key_caps):
                return dev
            dev.close()
        except (PermissionError, OSError):
            continue
    return None


def wait_for_gamepad():
    """Poll until a gamepad with the required buttons is found."""
    while True:
        dev = find_gamepad()
        if dev:
            print(f"Found gamepad: {dev.name} ({dev.path})", flush=True)
            return dev
        time.sleep(RESCAN_INTERVAL)


def monitor(dev):
    """
    Monitor the gamepad for BTN_MODE + BTN_START combo.
    Returns normally on device disconnect so caller can rescan.
    """
    pressed = set()
    combo_active = False
    last_trigger = 0

    try:
        for event in dev.read_loop():
            if event.type != ecodes.EV_KEY:
                continue
            if event.code not in REQUIRED_BUTTONS:
                continue

            if event.value == 1:  # key down
                pressed.add(event.code)
                if REQUIRED_BUTTONS.issubset(pressed):
                    combo_active = True
            elif event.value == 0:  # key up
                if combo_active:
                    now = time.monotonic()
                    if now - last_trigger >= COOLDOWN_SECONDS:
                        if is_gaming_active():
                            print("Gaming mode already active — ignoring combo", flush=True)
                        else:
                            print("Combo triggered — launching gaming mode", flush=True)
                            try:
                                subprocess.Popen(SWITCH_CMD)
                            except Exception as e:
                                print(f"Failed to launch: {e}", flush=True)
                        last_trigger = now
                    else:
                        print("Combo ignored — cooldown active", flush=True)
                    combo_active = False
                pressed.discard(event.code)
    except OSError:
        # Device disconnected
        print(f"Device disconnected: {dev.name}", flush=True)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    print("controller-gaming-trigger started", flush=True)

    while True:
        dev = wait_for_gamepad()
        monitor(dev)
        try:
            dev.close()
        except Exception:
            pass
        print("Rescanning for gamepad...", flush=True)


if __name__ == "__main__":
    main()
