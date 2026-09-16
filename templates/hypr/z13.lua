-- ASUS ROG Flow Z13 (2025) — Hyprland overrides.
--
-- Deployed by install.sh Phase 4 and required from ~/.config/hypr/hyprland.lua.
-- Loaded after Omarchy's defaults, so anything set here wins.

local home = os.getenv("HOME") or ""

-- ── Monitors ────────────────────────────────────────────────────────────────
--
-- The 4K display is pinned to 120 Hz on purpose: its EDID advertises 4K@120
-- (VIC 118), but its preferred detailed timing is 4K@60, so "preferred" would
-- negotiate 60 Hz.
--
-- The internal panel stays on while an external display is attached. Disabling
-- it on hotplug was tried and removed: it drove Omarchy's internal-monitor
-- toggle, whose clamshell watcher and modeless recovery loop issue hyprctl
-- reloads that raced the modeset and froze the session on unplug/replug.
-- Omarchy still disables the panel by itself in true clamshell (lid shut).
--
-- Positions are logical pixels from the top-left of the virtual layout, and
-- Hyprland's Y axis is inverted (negative is higher). The internal panel is
-- anchored at the origin so it renders correctly on its own when the external
-- display is unplugged. The external is offset so its bottom-left corner sits
-- at the internal panel's vertical midpoint:
--   eDP-1     2560x1600 @ 2.0  -> 1280x800  logical
--   HDMI-A-1  3840x2160 @ 1.25 -> 3072x1728 logical
--   x = eDP width        = 1280
--   y = 800/2 - 1728     = -1328
hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 2.0 })
hl.monitor({ output = "HDMI-A-1", mode = "3840x2160@120", position = "1280x-1328", scale = 1.25 })

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

-- ── Window rules ────────────────────────────────────────────────────────────

-- Center Lychee Slicer's file picker (XWayland spawns it at 0,0). The picker
-- uses class "Lycheeslicer" (lowercase s), distinct from the main window.
o.window("Lycheeslicer", { center = true })

-- Center Unreal Editor windows (dialogs and settings spawn off-center on
-- XWayland).
o.window("UnrealEditor", { center = true })

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
