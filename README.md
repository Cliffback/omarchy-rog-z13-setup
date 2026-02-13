# Omarchy ROG Z13 Setup

Post-install setup script for the ASUS ROG Flow Z13 (2025) running Omarchy Linux with the CachyOS kernel.

This script automates (and improves on) the hardware-specific configuration described in the [ROG Flow Z13 Linux Guide](https://github.com/cliffback/ASUS-ROG-Flow-Z13-2025-Linux-Guide-Omarchy-CachyOS-Kernel). It walks through each step interactively, checks whether work has already been done, and skips anything that is already in place. It is safe to re-run at any point.

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

The script runs six phases in order:

**Phase 0 - System update**

Updates keyrings and system packages via pacman.

**Phase 1 - CachyOS kernel and ASUS drivers**

Adds the CachyOS and G14 (asus-linux.org) repositories to pacman.conf, resolves Hyprland dependency conflicts between CachyOS and stable repos, installs the CachyOS kernel and headers, and installs asusctl and rog-control-center. Backs up pacman.conf before making changes.

**Phase 2 - asusd service fix**

The upstream asusd.service unit ships without an [Install] section, which prevents it from being enabled. This phase creates a systemd drop-in to add the missing section, then enables and starts the service.

**Phase 3 - Hardware support**

Installs split firmware packages (linux-firmware-amdgpu, linux-firmware-mediatek), removes the legacy linux-firmware-git if present, installs yay if needed, then installs AUR packages for tablet support (iio-hyprland-git, wvkbd-deskintl) and rofi-wayland. Applies a Wi-Fi stability fix for the MT7925E adapter by disabling ASPM.

**Phase 4 - Hyprland configuration**

Appends Z13-specific settings to ~/.config/hypr/hyprland.conf. This includes HiDPI scaling for the internal display (2x on eDP-1), auto-rotation via iio-hyprland, tablet input mapping, and keybinds for the virtual keyboard, ROG Quick menu, keyboard backlight cycling, and rog-control-center.

**Phase 5 - ROG Quick TDP menu**

Installs a rofi-based TDP power menu to ~/rog-quick.sh. The menu shows the current power draw and lets you pick from preset wattages (15W through 120W) or reset to the active asusctl profile defaults. TDP values are written to the asus-nb-wmi sysfs interface via pkexec.

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
templates/
  hyprland-z13.conf       Hyprland config block appended in Phase 4
  rog-quick.sh            TDP menu script deployed in Phase 5
```

## Disclaimer

This script modifies system packages, kernel, pacman repositories, systemd services, and configuration files. It is provided as-is with no warranty. Use it at your own risk. Review the source and use `--dry-run` before running it on your system. The author is not responsible for any damage or data loss that may result from using this script.

## License

MIT
