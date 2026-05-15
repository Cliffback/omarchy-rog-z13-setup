# ROG Flow Z13 — Key Mapping & Power Profiles

## Physical Keys

| Key | Keysym / Handler | Action |
|-----|-------------------|--------|
| **Side button** | `XF86Launch3` | Gaming mode (switch to gamescope/Steam) |
| **Fn+F5** (Armory Crate) | asusd (ACPI, no keysym) | Cycles power profile: Quiet → Balanced → Performance |
| **Fn+F6** (Screenshot) | `Super+Shift+S` (firmware) | Screenshot (`omarchy-capture-screenshot`) |
| **Fn+F11** (Kbd backlight) | `XF86KbdLightOnOff` | Cycle keyboard backlight (handled by omarchy default) |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Super+A` | ROG TDP power menu (`~/rog-quick.sh`) |
| `Super+Shift+S` | Screenshot |
| `Super+Shift+R` | ROG Control Center |
| `Super+V` | Virtual keyboard (tablet mode) |

## Power Profiles

The Armory Crate key (Fn+F5) cycles through ACPI platform profiles via asusd.
A notification is shown on each change via `~/.local/bin/rog-profile-notify.sh`.

### Check current profile

```bash
cat /sys/firmware/acpi/platform_profile
# or
asusctl profile get
```

### Available profiles

| Profile | Description |
|---------|-------------|
| `quiet` | Low fan speed, power saving |
| `balanced` | Default, moderate fans |
| `performance` | Max fans, full TDP |

## Known Issues

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
