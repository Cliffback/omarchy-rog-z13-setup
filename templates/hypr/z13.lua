-- ASUS ROG Flow Z13 (2025) — Hyprland overrides.
--
-- Deployed by install.sh Phase 4 and required from ~/.config/hypr/hyprland.lua.
-- Loaded after Omarchy's defaults, so anything set here wins.

local home = os.getenv("HOME") or ""

-- ── Monitors ────────────────────────────────────────────────────────────────
--
-- Display config lives in Omarchy's own ~/.config/hypr/monitors.lua, not here.
-- The scaling keys (SUPER+SLASH / SUPER+ALT+SLASH) rewrite omarchy_monitor_scale
-- there and reload, and both the catch-all and the eDP rule read that variable.
-- A per-output rule in this file would break them: Hyprland has no field-level
-- merge, so a rule that omits scale does NOT inherit the catch-all — it falls
-- back to PPI "auto" and the keys stop having any effect.
--
-- The internal panel stays on while an external display is attached. Disabling
-- it on hotplug was tried and removed: it drives Omarchy's internal-monitor
-- toggle, whose clamshell watcher and modeless recovery loop issue hyprctl
-- reloads that raced the modeset and froze the session on unplug/replug
-- (omarchy#7853, still open). Omarchy still disables the panel by itself in
-- true clamshell (lid shut).

-- ── Input ───────────────────────────────────────────────────────────────────
--
-- Only settings that differ from Omarchy's defaults are listed. Caps Lock is
-- the compose key, but Omarchy's default also moves Caps Lock onto both
-- Shifts; that misfires on this keyboard, so it is dropped.
hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "altgr-intl",
    kb_options = "compose:caps",
    repeat_rate = 40,
    repeat_delay = 600,
    numlock_by_default = true,

    touchpad = {
      natural_scroll = true,
      scroll_factor = 0.4,
    },

    -- Stylus maps to the internal panel.
    tablet = {
      transform = 0,
      output = "eDP-1",
    },
  },
})

-- ── Keybinds ────────────────────────────────────────────────────────────────
--
-- SUPER+V and SUPER+SHIFT+S are claimed by Omarchy defaults (universal paste
-- and the Google Maps web app), so they are unbound before rebinding.
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Virtual keyboard", "pkill wvkbd-deskintl || wvkbd-deskintl -L 300")

-- Power panel (battery, power profile, system stats).
o.bind("SUPER + Q", "Power", "omarchy-shell shell toggle omarchy.power")

-- ROG TDP cap menu.
o.bind("SUPER + SHIFT + Q", "ROG TDP cap", home .. "/.local/bin/rog-quick.sh")

hl.unbind("SUPER + SHIFT + S")
o.bind("SUPER + SHIFT + S", "Screenshot", "omarchy-capture-screenshot")

-- ROG Control Center.
o.bind("SUPER + SHIFT + R", "ROG Control Center", "rog-control-center")

-- Screenshot on F12 as well as Omarchy's PRINT.
o.bind("SUPER + F12", "Screenshot", "omarchy-capture-screenshot")

-- ── Autostart ───────────────────────────────────────────────────────────────
--
-- Platform profile change notification (Fn+F5 / Armory Crate key).
o.launch_on_start(home .. "/.local/bin/rog-profile-notify.sh")

-- Automatic screen rotation from the accelerometer (iio-sensor-proxy). The
-- wrapper suppresses a libdbus abort on the binary's exit paths; it execs
-- /usr/bin/iio-hyprland, which emits `hyprctl eval` (hl.monitor/hl.config) and
-- defaults to eDP-1. Launched by absolute path: the compositor's PATH puts
-- /usr/bin before ~/.local/bin, so a bare name would miss the wrapper.
o.launch_on_start(home .. "/.local/bin/iio-hyprland")

-- ── Window rules ────────────────────────────────────────────────────────────

-- Center Lychee Slicer's file picker (XWayland spawns it at 0,0). The picker
-- uses class "Lycheeslicer" (lowercase s), distinct from the main window.
o.window("Lycheeslicer", { center = true })

-- Center Unreal Editor windows (dialogs and settings spawn off-center on
-- XWayland).
o.window("UnrealEditor", { center = true })

-- ChituManager (CHITUBOX's remote printer manager) is deliberately left tiled:
-- a floating rule crashes it (OpenSSL 3.x incompatibility), and its window
-- fits a tile fine at 1200x800 native. No rule is needed — this note just
-- records why, so nobody "fixes" it by floating the window.

-- Fix Blender's native Wayland file dialog (too small / unresizable).
o.window({ class = "blender", title = "Blender File View" }, {
  float = true,
  size = { 1400, 900 },
  center = true,
})

-- VPN window follows the standard floating treatment.
o.window("org.omarchy.omarchy-vpn", { tag = "+floating-window" })

-- Silence the fcitx5 Wayland diagnose warning.
hl.env("FCITX_NO_WAYLAND_DIAGNOSE", "1")
