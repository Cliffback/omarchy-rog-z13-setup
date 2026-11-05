# ROG Flow Z13 — Key Mapping & Power Profiles

## Physical Keys

| Key | Keysym / Handler | Action |
|-----|-------------------|--------|
| **Side button** | `XF86Launch3` | Toggle gaming mode (enter from Hyprland, exit from gamescope) |
| **Fn+F5** (Armory Crate) | asusd (ACPI, no keysym) | Cycles power profile: Quiet → Balanced → Performance |
| **Fn+F6** (Screenshot) | `Super+Shift+S` (firmware) | Screenshot (`omarchy-capture-screenshot`) |
| **Fn+F11** (Kbd backlight) | `XF86KbdLightOnOff` | Cycle keyboard backlight (handled by omarchy default) |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Super+Q` | Power profile picker (`omarchy-menu power`) |
| `Super+Shift+Q` | ROG TDP cap menu (`~/.local/bin/rog-quick.sh`) |
| `Super+Shift+S` | Screenshot |
| `Super+Shift+R` | ROG Control Center |
| `Super+V` | Virtual keyboard (tablet mode) |

## Power Profiles

The Armory Crate key (Fn+F5) cycles through ACPI platform profiles via asusd.
A notification is shown on each change via `~/.local/bin/rog-profile-notify.sh`.

Fan behaviour comes from the **firmware's own per-profile table**. asusd's
custom fan curves are disabled by design (Phase 2b): on this machine a custom
curve was observed to pin the second fan at ~6300 RPM; re-tests at warm idle
did not reproduce it, so the probe is the check. Quiet is the silent profile
only while its custom curve is off. See
[docs/z13-fan-curve-gz302ea.md](z13-fan-curve-gz302ea.md).

### Check current profile

```bash
cat /sys/firmware/acpi/platform_profile
# or
asusctl profile get
```

### Available profiles

All profiles share the same firmware TDP ceiling (120W SPL). The difference is
the firmware fan table and CPU boost behavior (EPP). The Z13's cooling sustains
~70-75W max.

| Profile | Fan Behavior | CPU Boost (EPP) | Practical Wattage |
|---------|-------------|-----------------|-------------------|
| `quiet` | Low/silent | Conservative (Power) | ~15-30W |
| `balanced` | Moderate | Moderate (BalancePower) | ~30-50W |
| `performance` | Aggressive | Full boost (Performance) | ~70-75W (thermal limit) |

### TDP Power Menu (Super+Shift+Q)

The TDP menu (`~/.local/bin/rog-quick.sh`) caps the APU power limit below the
firmware default. This is the only way to set a specific wattage — profiles only
control fan/boost behavior. Manual TDP caps are reset when switching profiles
via Fn+F5.

| TDP Cap | Use Case |
|---------|----------|
| Default | Reset to profile defaults (uncapped) |
| 15W | Silent, max battery life |
| 30W | Light browsing, document editing |
| 45W | Moderate multitasking |
| 70W | Max sustained (thermal ceiling) |

## Known Issues

### Fan 2 observed pinned at ~6300 RPM with a custom fan curve

On GZ302EA with BIOS 314, an asusd custom fan curve was observed to pin
`gpu_fan` at ~6300–6400 RPM even at 36 °C and 12–18 W. Controlled re-tests at
45–50 °C did not reproduce it, so `scripts/z13-fan-curve-probe.sh` is the check.
The firmware's per-profile table is fine: with the curves off, Quiet is the
quietest and Balanced/Performance ramp with temperature and load (Performance
reached 4700–5100 RPM under stress). Phase 2b keeps the custom curves disabled as
the conservative default.

Do not re-enable a curve to quieten the machine. The working lever for lower
temperatures and fan noise is the **TDP cap** (Phase 5, `Super+Shift+Q`). See
[docs/z13-fan-curve-gz302ea.md](z13-fan-curve-gz302ea.md) for the measurements,
the probe, and the z13ctl-plus alternative.

### Keyboard backlight not persisting across reboots

The Z13 has two USB aura devices (`0b05:1a30` keyboard, `0b05:18c6` N-KEY) that
both bind to the same `asus::kbd_backlight` sysfs node. asusd registers them as
separate LED controllers and restores brightness per-device on boot. If the N-KEY
config (`/etc/asusd/aura_18c6.ron`) has `brightness: Off`, it overrides the
keyboard brightness on boot. The install script (phase 2) fixes this by setting
both configs to `brightness: High`.

### `asusctl leds next` fails with "Multiple asusd interfaces devices found"

Same root cause as above — asusd exposes two dbus interfaces for the same
backlight device. The CLI refuses to act when it finds multiple interfaces.
Keyboard backlight cycling works via the hardware Fn key because omarchy handles
`XF86KbdLightOnOff` using `brightnessctl` directly (`omarchy-brightness-keyboard`).
