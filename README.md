# Omarchy ROG Z13 Setup

Post-install setup script for the ASUS ROG Flow Z13 (2025) running Omarchy Linux with the CachyOS kernel.

This script automates (and improves on) the hardware-specific configuration described in the [ROG Flow Z13 Linux Guide](https://github.com/ib99/ASUS-ROG-Flow-Z13-2025-Linux-Guide-Omarchy-CachyOS-Kernel). It walks through each step interactively, checks whether work has already been done, and skips anything that is already in place. It is safe to re-run at any point.

## Usage

```bash
git clone https://github.com/cliffback/omarchy-rog-z13-setup.git
cd omarchy-rog-z13-setup
./install.sh
```

The script prompts with y/n before each phase. If a phase has already been completed, it is automatically skipped.

After Phase 1 (kernel installation), the script will offer to reboot. Re-run the script after rebooting to continue with the remaining phases.

### Dry-run mode

To see what the script would do without making any changes:

```bash
./install.sh --dry-run
```

In dry-run mode all prompts are auto-answered yes and commands are printed instead of executed.

## What it does

The script runs twelve phases in order:

**Phase 0 - System update**

Updates keyrings and system packages via pacman.

**Phase 1 - CachyOS kernel and ASUS drivers**

Adds the CachyOS and G14 (asus-linux.org) repositories to pacman.conf, resolves Hyprland dependency conflicts between CachyOS and stable repos, installs the CachyOS kernel and headers, and installs asusctl and rog-control-center. Backs up pacman.conf before making changes.

**Phase 2 - asusd service fix**

The asusd.service unit currently ships without an [Install] section, which prevents it from being enabled. This phase creates a systemd drop-in to add the missing section, then enables and starts the service.

**Phase 3 - Hardware support**

Installs split firmware packages (linux-firmware-amdgpu, linux-firmware-mediatek, linux-firmware-intel, linux-firmware-cirrus), AUR packages for tablet support (iio-hyprland-git, wvkbd-deskintl) and rofi-wayland. Applies a Wi-Fi stability fix for the MT7925E adapter by disabling ASPM.

Also fixes an audio issue where speakers go silent after plugging/unplugging headphones. Omarchy applies a `soft-mixer` WirePlumber config to all ASUS ROG devices, but this prevents PipeWire from managing hardware mixer switches (Speaker/Headphone), breaking jack detection switching on the Z13's ALC294 codec. This phase removes that config so PipeWire can properly handle speaker/headphone switching. See [basecamp/omarchy#4821](https://github.com/basecamp/omarchy/issues/4821) for details.

**Phase 4 - Hyprland configuration**

Appends Z13-specific settings to ~/.config/hypr/hyprland.conf. This includes HiDPI scaling for the internal display (2x on eDP-1), auto-rotation via iio-hyprland, tablet input mapping, and keybinds for the virtual keyboard, ROG Quick menu, keyboard backlight cycling, and rog-control-center.

**Phase 5 - ROG Quick TDP menu**

Installs a rofi-based TDP power menu to ~/rog-quick.sh. The menu shows the current power draw and lets you pick from preset wattages (15W through 120W) or reset to the active asusctl profile defaults. TDP values are written to the asus-nb-wmi sysfs interface via pkexec. Note that custom TDP values are reset whenever the asusctl power profile changes.

**Phase 6 - Steam Gamescope (optional)**

Installs the NO SIGNAL Gamescope setup for Steam Gaming Mode, including session files and optional Decky Loader plugins. Also installs Heroic Games Launcher for Epic/GOG/Amazon games.

**Phase 7 - CachyOS Mirror Optimization (optional)**

Installs cachyos-rate-mirrors and ranks mirrors for optimal download speeds.

**Phase 8 - Ollama GPU Setup (optional)**

Installs ollama-vulkan for GPU-accelerated large language model inference using the Vulkan backend (recommended for AMD RDNA 3.5). Configures Ollama as a systemd service with optimized settings: flash attention enabled, 256k context window, 24-hour model keep-alive, and up to 3 concurrent models. Optionally enables network access and installs nvtop for GPU monitoring.

Note: For optimal performance with large models (30B+), set iGPU memory allocation to 96GB in BIOS.

**Phase 9 - Audio EQ (optional)**

Installs EasyEffects with Z13-optimized speaker presets from [Naomarik/Z13-StrixHalo-Omarchy](https://github.com/Naomarik/Z13-StrixHalo-Omarchy). Configures automatic preset loading: "IRZ13 Flow" for the internal speakers and "Perfect EQ" as fallback for headphones and other output devices. EasyEffects is set to start automatically in service mode.

**Phase 10 - Thunderbolt Dock Fix (optional)**

Installs udev rules to prevent the Intel Alpine Ridge Thunderbolt controller from entering D3 sleep and to trigger a PCI bus rescan on dock replug. The Z13's UEFI firmware has a buggy ACPI `_PS3` method that times out when the controller enters D3, breaking the PCIe tunnel to the dock and preventing its USB hub (including Ethernet) from enumerating. Unplugging and replugging the dock also corrupts the PCI topology, so a second rule triggers a rescan to recover automatically. Only needed if you use a Thunderbolt dock. See [docs/thunderbolt-dock-d3-fix.md](docs/thunderbolt-dock-d3-fix.md) for the full investigation.

**Phase 11 - Controller Gaming Mode Trigger (optional)**

Installs a background service that monitors any connected gamepad for a **Guide/PS button + Start** combo press and automatically switches to Gamescope gaming mode (via `/usr/local/bin/switch-to-gaming`). Works with any standard gamepad (PlayStation, Xbox, Switch Pro, etc.) — the controller is detected automatically by its capabilities, not by vendor/product ID. The service only runs under Hyprland and is inactive inside Gamescope sessions, so it won't interfere with gameplay. Uses `python-evdev` and runs as a systemd user service.

To remove:
```bash
systemctl --user disable --now controller-gaming-trigger.service
rm ~/.config/systemd/user/controller-gaming-trigger.service
sudo rm /usr/local/bin/controller-gaming-trigger
```

## Custom Hyprland keybindings

Phase 4 adds the following keybindings to your Hyprland config:

| Keybind | Action |
|---|---|
| `Super + V` | Toggle on-screen virtual keyboard (wvkbd) |
| `Super + A` | Open ROG Quick TDP power menu |
| `XF86Launch3` (dedicated side button) | Open ROG Quick TDP power menu |
| `Fn + F11` (`XF86KbdLightOnOff`) | Cycle keyboard backlight modes |
| `Super + Shift + R` | Open ROG Control Center |

## File structure

```
install.sh                Main entry point
lib/
  common.sh               Shared utilities (logging, prompts, checks, dry-run wrappers)
  phase0_update.sh        System update
  phase1_kernel.sh        CachyOS repos, Hyprland fix, kernel, ASUS tools
  phase2_asusd.sh         asusd service fix
  phase3_hardware.sh      Firmware, tablet utilities, Wi-Fi fix
  phase4_hyprland.sh      Hyprland configuration
  phase5_rogquick.sh      ROG Quick TDP menu
  phase6_gaming.sh        Gaming Tools
  phase7_mirrors.sh       CachyOS mirror optimization
  phase8_ollama.sh        Ollama GPU setup (Vulkan)
  phase9_audio_eq.sh      Audio EQ (EasyEffects)
  phase10_thunderbolt_dock.sh  Thunderbolt dock D3 sleep fix
  phase11_controller_gaming.sh Controller gaming mode trigger
templates/
  hyprland-z13.conf       Hyprland config block appended in Phase 4
  rog-quick.sh            TDP menu script deployed in Phase 5
  gaming-mode-hotfix.sh   Gaming mode capability fixes for Phase 6
  99-thunderbolt-no-d3.rules  Thunderbolt dock udev rules for Phase 10
  controller-gaming-trigger.py   Gamepad combo listener for Phase 11
  controller-gaming-trigger.service  Systemd user service for Phase 11
```

## Disclaimer

This script modifies system packages, kernel, pacman repositories, systemd services, and configuration files. It is provided as-is with no warranty. Use it at your own risk. Review the source and use `--dry-run` before running it on your system. The author is not responsible for any damage or data loss that may result from using this script.

## License

MIT
