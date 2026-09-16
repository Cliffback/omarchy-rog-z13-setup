#!/bin/bash
# iio-hyprland wrapper — deployed to ~/.local/bin/iio-hyprland by Phase 4.
#
# Two reasons this exists:
#
# 1. The upstream binary calls dbus_connection_close() on a shared connection
#    obtained from dbus_bus_get(), which trips a libdbus assertion
#    ("Applications must not close shared connections") and aborts with SIGABRT
#    on every exit path (e.g. the monitor not being up yet at session start).
#    Omarchy's crash watcher then raises a spurious "Process crashed"
#    notification. DBUS_FATAL_WARNINGS=0 downgrades the abort to a clean exit.
#
# It is launched by absolute path from z13.lua (the compositor's PATH puts
# /usr/bin before ~/.local/bin, so a bare `iio-hyprland` would not find this
# wrapper) and execs the real binary by absolute path, so there is no recursion.
#
# The installed package (iio-hyprland-git r93+) already emits `hyprctl eval`
# with hl.monitor/hl.config, so no hyprctl shim is needed under the Lua parser.
# The output defaults to eDP-1 upstream, which is the Z13's internal panel.

export DBUS_FATAL_WARNINGS=0

exec /usr/bin/iio-hyprland "$@"
