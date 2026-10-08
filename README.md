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

The script runs eighteen phases in order:

**Phase 0 - System update**

Updates keyrings and system packages via pacman.

**Phase 1 - CachyOS kernel and ASUS drivers**

Adds the CachyOS and G14 (asus-linux.org) repositories to pacman.conf, resolves Hyprland dependency conflicts between CachyOS and stable repos, installs the CachyOS kernel and headers, and installs asusctl and rog-control-center. Backs up pacman.conf before making changes.

**Phase 2 - asusd service fix**

The asusd.service unit currently ships without an [Install] section, which prevents it from being enabled. This phase creates a systemd drop-in to add the missing section, then enables and starts the service.

**Phase 3 - Hardware support**

Installs split firmware packages (linux-firmware-amdgpu, linux-firmware-mediatek, linux-firmware-intel, linux-firmware-whence, linux-firmware-cirrus) and marks them as explicitly installed to protect them from Omarchy's orphan package cleanup. Installs AUR packages for tablet support (iio-hyprland-git, wvkbd-deskintl) and rofi-wayland. Applies a Wi-Fi stability fix for the MT7925E adapter by disabling ASPM.

Also fixes an audio issue where speakers go silent after plugging/unplugging headphones. Omarchy applies a `soft-mixer` WirePlumber config to all ASUS ROG devices, but this prevents PipeWire from managing hardware mixer switches (Speaker/Headphone), breaking jack detection switching on the Z13's ALC294 codec. This phase removes that config so PipeWire can properly handle speaker/headphone switching. See [basecamp/omarchy#4821](https://github.com/basecamp/omarchy/issues/4821) for details.

Additionally initializes the speaker amplifier mixer (ALC294 + CS35L41) and enables HDMI audio auto-profile for AMD HDMI controllers so external monitors appear as audio output devices.

This phase also removes the retired Z13 power-profile churn machinery (the battery-keyed `99-power-profile.rules` / `99-wifi-powersave.rules` udev rules, the debounced profile wrapper, the Wi-Fi power-save wrapper, and the post-update hook). Under Omarchy 4 (Quattro) profile switching moved into Quickshell and no longer inherits the AC0 flap, so the workaround is obsolete — and broken, since `~/.local/share/omarchy` is now a symlink to root-owned `/usr/share/omarchy`. See [docs/z13-power-profile-churn-fix.md](docs/z13-power-profile-churn-fix.md).

**Phase 4 - Hyprland configuration**

Installs a Z13 Hyprland module to ~/.config/hypr/z13.lua, required from ~/.config/hypr/hyprland.lua. Omarchy 4 (Quattro) reads `.lua`, not `.conf`, so the old append-to-hyprland.conf approach is dead. The module covers input, keybinds, autostart, and window rules: tablet stylus mapping to eDP-1, the virtual keyboard, the power panel, the ROG Quick TDP menu, screenshot capture, and rog-control-center. It also installs a profile change notification script that shows a desktop notification when the platform profile is cycled via Fn+F5.

Display config is deliberately left in Omarchy's own ~/.config/hypr/monitors.lua. Phase 4 sets the internal panel's default scale to 1.6 (only when the file still carries Omarchy's stock `"auto"`, so a scale you picked with the keys is never clobbered) and appends the two Z13 rules. Both the catch-all and the eDP-1 rule read `omarchy_monitor_scale`, which is what makes Omarchy's scaling keys (`SUPER+SLASH` / `SUPER+ALT+SLASH`) work: the keys rewrite that variable and reload. z13.lua pins no monitor, because Hyprland has no field-level merge — a per-output rule that omits `scale` does not inherit the catch-all, it falls back to PPI `"auto"`, which silently freezes the scale.

The external 4K display is pinned to 3840x2160@120 because its EDID prefers 4K@60 (the 120Hz mode is advertised separately), at scale 1.25, offset so its bottom-left corner meets the internal panel's bottom-left (`1600x-728` at the 1.6 default). Note that 4K@120 negotiates YCbCr 4:2:0 (half chroma) — 4:4:4 needs more bandwidth than the DP-PCON HDMI path provides; 4K@100 4:4:4 is the compromise. See [docs/external-display-4k120-chroma.md](docs/external-display-4k120-chroma.md).

The internal panel stays on while an external display is attached: disabling it on hotplug drives Omarchy's internal-monitor toggle, whose clamshell watcher and modeless recovery loop issue `hyprctl reload`s that race the modeset and freeze the session on unplug/replug (omarchy#7853, still open upstream). Omarchy still disables the panel by itself in true clamshell (lid shut). The HDMI offset is static, so changing the internal scale while docked shifts it — the fix for that is the internal-disable bug above.

Auto-rotation is handled by `iio-hyprland`, launched from `z13.lua` through a wrapper at `~/.local/bin/iio-hyprland`. The wrapper only sets `DBUS_FATAL_WARNINGS=0`: upstream's binary calls `dbus_connection_close()` on a shared connection, which aborts with SIGABRT on its exit paths (e.g. the monitor not being up yet at session start) and trips Omarchy's crash watcher. The AUR package tracks upstream master, which emits `hyprctl eval` for the Lua parser — Phase 3 rebuilds `iio-hyprland-git` when the installed build still uses the dead `hyprctl keyword`.

**Phase 5 - ROG Quick TDP menu**

Installs a TDP power menu to ~/.local/bin/rog-quick.sh. The menu (using omarchy-menu-select) shows the current profile and power draw, and lets you pick from preset wattages (15W, 30W, 45W, 70W) or reset to the active asusctl profile defaults. TDP values are written to the asus-nb-wmi sysfs interface via pkexec. Note that custom TDP values are reset whenever the asusctl power profile changes.

**Phase 6 - Gaming Tools (optional)**

Installs Gamescope gaming mode (Steam Big Picture in a dedicated compositor session, similar to Steam Deck). Includes session switching between Hyprland and Gamescope via SDDM, performance tuning, NetworkManager handoff, and external drive auto-mounting. Optionally installs Decky Loader (plugin framework), SimpleDeckyTDP (TDP control plugin), Heroic Games Launcher (Epic/GOG/Amazon), a Heroic Gamescope compatibility patch, and EmuDeck (emulator setup and ROM management).

Gaming mode itself is provided by [DeckShift](https://github.com/28allday/deckshift), vendored as a git submodule at `templates/deckshift/` and forked to [Cliffback/deckshift-z13](https://github.com/Cliffback/deckshift-z13) with Z13-specific fixes on the `z13` branch (side-button toggle, external-display default, 180 Hz refresh limits, Quattro NetworkManager cleanup, consolidated pacman hook). Clone with `--recursive`, or let the installer initialise the submodule on first run.

**Phase 7 - CachyOS Mirror Optimization (optional)**

Installs cachyos-rate-mirrors and ranks mirrors for optimal download speeds.

**Phase 8 - Ollama GPU Setup (optional)**

Installs ollama-vulkan for GPU-accelerated large language model inference using the Vulkan backend (recommended for AMD RDNA 3.5). Configures Ollama as a systemd service with optimized settings: flash attention enabled, 256k context window, 24-hour model keep-alive, and up to 3 concurrent models. Optionally enables network access and installs nvtop for GPU monitoring.

Note: For optimal performance with large models (30B+), set iGPU memory allocation to 96GB in BIOS.

**Phase 9 - Audio Amplifier Gain (optional)**

Increases the CS35L41 speaker amplifier gain from 15.5dB (default) to 19.5dB by symlinking firmware bincfg files. This is a hardware-level fix that makes the speakers significantly louder, closer to Windows/Dolby volume levels. Note: very high volume (above ~80%) may cause minor bass distortion on low frequencies, which is normal for laptop speakers at full power. Requires a reboot to take effect. See [this investigation](https://dev.to/ankk98/rog-flow-z13-2025-linux-audio-quality-investigation-3ggk) for background.

To revert to default gain (15.5dB):
```bash
cd /lib/firmware/cirrus
sudo ln -sf cs35l41/bincfgs/cs35l41-dsp1-15_5dB.bincfg.zst cs35l41-dsp1-spk-prot-10431fb3-l0.bincfg.zst
sudo ln -sf cs35l41/bincfgs/cs35l41-dsp1-15_5dB.bincfg.zst cs35l41-dsp1-spk-prot-10431fb3-r0.bincfg.zst
# Then reboot
```

<details>
<summary>Uninstalling EasyEffects (from previous versions of this script)</summary>

If you previously ran this script when it installed EasyEffects, you can remove it:
```bash
sudo pacman -Rns easyeffects
rm -rf ~/.config/easyeffects ~/.local/share/easyeffects
rm -f ~/.config/autostart/easyeffects-service.desktop
```
</details>

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

**Phase 12 - Audio Sink Routing**

Configures WirePlumber with priority-based automatic audio sink switching: Bluetooth > HDMI > Internal speakers. Disables saved default restoration so the priority routing always takes effect when devices connect or disconnect.

**Phase 13 - Hibernate Wake Fix (optional)**

Prevents spurious wakes during hibernate caused by the AMD GPIO controller (AMDI0030) on Ryzen 7000+ / Strix Halo. Adds a kernel parameter via limine-entry-tool to ignore interrupt pins 2 and 3. Requires a reboot to take effect. See the [Arch Wiki](https://wiki.archlinux.org/title/Power_management/Wakeup_triggers#Ryzen_7000_Series) for background.

**Phase 14 - Lychee Slicer (optional)**

Installs Lychee Slicer from AUR and applies a DPI scaling fix. Lychee's Electron-based UI renders ~1.25x oversized on Wayland; a launcher wrapper reads the current monitor scale and applies a 0.8 correction factor so the UI matches other apps. Also registers the `.lys` MIME type so file managers can open Lychee project files directly.

**Phase 15 - Orca Bambu Studio (optional)**

Installs Orca Bambu Studio from AUR and applies a DPI scaling fix. Orca's wxWidgets UI is oversized on Wayland; a launcher wrapper sets `GDK_DPI_SCALE=0.8` to compensate. Creates a desktop entry that shadows the default one. Also registers as the handler for `bambustudio://` and `bambustudioopen://` URI schemes so MakerWorld's "Open in BambuStudio" button launches Orca.

**Phase 16 - Bambu Studio (optional)**

Installs Bambu Studio AppImage from AUR and applies a DPI scaling fix. Bambu Studio's wxWidgets UI is oversized on Wayland; a launcher wrapper sets `GDK_DPI_SCALE=0.8` to compensate. Creates a desktop entry that shadows the default one. No MIME registration needed — it is already handled by the system desktop entry.

**Phase 17 - Unreal Engine 5 (optional)**

Installs Unreal Engine 5 binary releases with Wayland/X11 fixes, HiDPI scaling (`fake_dpi.so`), launcher aliases, desktop integration, and bidirectional Neovim support. Requires manually downloading a `Linux_Unreal_Engine_*.zip` from Epic first. After installation, optionally configures Neovim/LazyVim with the official `mbwilding/UnrealEngine.nvim` plugin for LSP, building, and bidirectional file opening between UE Editor and nvim.

Features include:
- Double-click a C++ class in UE → opens in your running nvim instance
- `:UnrealEngine open` from nvim → launches UE for the current project
- Auto-respawn: if nvim is closed, UE spawns a new instance automatically
- Dead socket detection via `timeout 3` — UE never freezes
- Smart `nvim` wrapper script handles any socket path (including random `v:servername` paths)
- `setsid` detaches spawned terminals from UE's process tree so they survive

For full details, see [`docs/unreal-engine-neovim-integration.md`](docs/unreal-engine-neovim-integration.md).

Two standalone scripts provide a complete bidirectional integration between Unreal Engine 5 and Neovim for C++ development on the Z13:

- **`scripts/install-unreal-engine.sh`** — Installs UE5 binary releases with Wayland/X11 fixes, HiDPI scaling (`fake_dpi.so`), launcher aliases, and desktop integration
- **`scripts/setup-ue-neovim.sh`** — Configures LazyVim with the official `mbwilding/UnrealEngine.nvim` plugin for LSP, building, and bidirectional file opening

Features include:
- Double-click a C++ class in UE → opens in your running nvim instance
- `:UnrealEngine open` from nvim → launches UE for the current project
- Auto-respawn: if nvim is closed, UE spawns a new instance automatically
- Dead socket detection via `timeout 3` — UE never freezes
- Smart `nvim` wrapper script handles any socket path (including random `v:servername` paths)
- `setsid` detaches spawned terminals from UE's process tree so they survive

For full details, see [`docs/unreal-engine-neovim-integration.md`](docs/unreal-engine-neovim-integration.md).

## Custom Hyprland keybindings

Phase 4 adds the following keybindings to your Hyprland config:

| Keybind | Action |
|---|---|
| `Super + V` | Toggle on-screen virtual keyboard (wvkbd) |
| `Super + Q` | Open power profile picker (omarchy-menu) |
| `Super + Shift + Q` | Open ROG Quick TDP cap menu |
| `Super + Shift + S` | Take screenshot (omarchy-capture-screenshot) |
| `Super + Shift + R` | Open ROG Control Center |

## File structure

```
install.sh                Main entry point
lib/
  common.sh               Shared utilities (logging, prompts, checks, dry-run wrappers)
  phase0_update.sh        System update
  phase1_kernel.sh        CachyOS repos, Hyprland fix, kernel, ASUS tools
  phase2_asusd.sh         asusd service fix
  phase3_hardware.sh      Firmware, tablet utilities, Wi-Fi fix, audio fixes
  phase4_hyprland.sh      Hyprland configuration
  phase5_rogquick.sh      ROG Quick TDP menu
  phase6_gaming.sh        Gaming Tools
  phase7_mirrors.sh       CachyOS mirror optimization
  phase8_ollama.sh        Ollama GPU setup (Vulkan)
  phase9_audio_eq.sh      Audio Amplifier Gain (CS35L41 bincfg)
  phase10_thunderbolt_dock.sh  Thunderbolt dock D3 sleep fix
  phase11_controller_gaming.sh Controller gaming mode trigger
  phase12_audio_routing.sh     Audio sink priority routing
  phase13_hibernate_wake.sh    Hibernate wake fix (GPIO workaround)
  phase14_lychee.sh            Lychee Slicer install + desktop integration
  phase15_orca_scaling.sh      Orca Bambu Studio DPI scaling fix
  phase16_bambu_scaling.sh     Bambu Studio DPI scaling fix
  phase17_unreal_engine.sh     Unreal Engine 5 installer + Neovim integration
templates/
  hypr/z13.lua            Z13 Hyprland module (monitors, input, binds, rules) — Phase 4
  rog-profile-notify.sh   Platform profile change notification script
  rog-quick.sh            TDP menu script deployed in Phase 5
  deckshift/              DeckShift gaming-mode submodule (fork: deckshift-z13, z13 branch)
  gamescope-hdr-session-steam  HDR session override for Phase 6 (optional, disabled by default)
  patch-heroic-gamescope.sh    Heroic Gamescope compatibility patch
  hibernate-wake-fix.sh   Standalone hibernate wake fix script
  99-thunderbolt-no-d3.rules  Thunderbolt dock udev rules for Phase 10
  controller-gaming-trigger.py   Gamepad combo listener for Phase 11
  controller-gaming-trigger.service  Systemd user service for Phase 11
  unreal-engine/
    nvim-wrapper.sh       Smart nvim wrapper for UE integration
    fake_dpi.c            HiDPI interceptor for UE on HiDPI displays
    *.png                 Application icons
    unreal-engine.xml     MIME type for .uproject files
scripts/
  install-unreal-engine.sh    Standalone UE5 binary installer
  setup-ue-neovim.sh          Neovim/LazyVim UE integration setup
  prep-quattro-upgrade.sh     Back up customizations before the Omarchy 4 upgrade
  z13-power-validate.sh       Record power-profile signals across a charge cycle
  scx-bench.sh                CPU scheduler benchmark harness
  scx-ab-test.sh              EEVDF vs sched_ext A/B comparison
  scx-sweep.sh                Scheduler config sweep
  scx-latency.c               Wake-latency measurement tool
docs/
  unreal-engine-neovim-integration.md  Full UE+nvim integration guide
  z13-power-profile-churn-fix.md       AC0 flapping bug: cause, fix, validation
  external-display-4k120-chroma.md     4K@120 YCbCr 4:2:0 bandwidth limit
  omarchy-quattro-upgrade-checklist.md Omarchy 4 upgrade plan
  scx-sched-ext-evaluation.md          sched_ext evaluation (not adopted)
```

## Disclaimer

This script modifies system packages, kernel, pacman repositories, systemd services, and configuration files. It is provided as-is with no warranty. Use it at your own risk. Review the source and use `--dry-run` before running it on your system. The author is not responsible for any damage or data loss that may result from using this script.

## License

MIT
