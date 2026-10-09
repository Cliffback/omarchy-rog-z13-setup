# Omarchy Quattro (v4) Upgrade Checklist — ROG Flow Z13

Prepared 2026-09-15. Target: Omarchy 3.8.5 → 4.0.x (Quattro), CachyOS + Omarchy edge.

## Why this needs preparation

Quattro is a one-way rewrite: the desktop shell moves to Quickshell (Waybar,
Walker, Mako, SwayOSD, hyprlock, hypridle, swaybg are all removed), Omarchy
internals move from a git checkout to pacman packages, and Hyprland configs move
from `.conf` to `.lua`. This machine has substantial customizations that depend
on the old layout.

**The snapper snapshot does NOT protect your customizations.** `snapper` is
configured with `SUBVOLUME="/"`, so it snapshots only the `@` subvolume:

| Path | Subvolume | Snapshotted? |
|---|---|---|
| `/` (packages, `/usr`, `/etc`) | `@` | yes |
| `/home` (incl. `~/.config`, `~/.local/share/omarchy`) | `@home` | **no** |
| `/boot` (ESP, UKIs, `limine.conf`) | vfat | **no** |
| `/var/log`, `/var/cache/pacman/pkg` | `@log`, `@pkg` | **no** |

Rolling back `@` restores old binaries while `/home` stays Quattro-era — a mixed,
possibly unbootable state. Back up dotfiles separately.

## Decisions already made

- **Repos:** keep CachyOS (~900 znver4 packages + Cachy kernel), use Omarchy
  **edge** so `core`/`extra` track current Arch and match CachyOS. Stable +
  CachyOS is the highest-skew combination.
- **Kernel:** `linux-cachyos` is not in Quattro's retired list, so it survives.
  The upgrade does not remove it.
- **Channel:** edge (not stable) to minimise repo skew.

## Pre-flight

- [ ] **Connect AC.** Never upgrade on battery.
- [ ] **Free disk.** Upgrade needs headroom for the `.bak` checkout (~400M),
      package downloads, and the new base set. Check `df -h /`.
- [ ] **Commit and push this repo.** It is currently ahead of origin with
      uncommitted changes.
- [ ] **Back up dotfiles** (see archive list below).
- [ ] **Manual snapshot:** `omarchy-snapshot create` in addition to the one the
      upgrade takes.
- [ ] **Stop sched_ext** if enabled: `sudo systemctl stop scx`. (Not currently
      enabled — see `docs/scx-sched-ext-evaluation.md`.)

### Archive list

Copy these somewhere outside `~` (or to a git repo):

```
~/.config/hypr/                      # all .conf overrides + gaming-mode.conf
~/.config/waybar/                    # retired by Quattro
~/.config/walker/                    # retired by Quattro
~/.config/omarchy/hooks/             # post-update hook
~/.config/omarchy/extensions/        # old menu.sh mechanism
~/.local/bin/                        # rog-*, *-scaled, affinity-open
~/.local/share/omarchy/bin/          # PATCHED internals + untracked scripts
/etc/limine-entry-tool.d/
/etc/default/limine
/etc/mkinitcpio.conf.d/
/etc/udev/rules.d/99-power-profile.rules
/etc/pacman.conf
```

## What the upgrade does automatically

- Snapper snapshot, repoints `[omarchy]` + `mirrorlist` (preserves CachyOS/g14 blocks)
- Installs `omarchy`/`omarchy-settings` + base packages; removes retired packages
  (waybar, walker, mako, swayosd, hypridle, hyprlock, iwd…)
- Backs up `~/.config/{waybar,swayosd,mako,walker}`
- Moves `~/.local/share/omarchy` → `.bak` and symlinks it to `/usr/share/omarchy`
- Switches iwd → NetworkManager, enables sddm, runs migrations, requires reboot

## What breaks (must be reworked after reboot)

1. **All Hyprland `.conf` overrides become dead.** Quattro reads `.lua`. This
   kills: eDP-1 monitor + `iio-hyprland` auto-rotation, tablet input mapping,
   `wvkbd` keybind, ROG keys (Super+Q/Shift+Q/Shift+S/Shift+R), windowrules
   (Lychee, Unreal, Blender, ChituManager), gaming-mode bind.
   **Ported** to `~/.config/hypr/z13.lua` (Phase 4), except auto-rotation —
   see item 10.
2. **Patched Omarchy internals are lost** — `omarchy-menu`,
   `omarchy-hibernation-*`, `omarchy-brightness-keyboard`, `omarchy-system-lock`,
   plus untracked `omarchy-powerprofiles-set-debounced`,
   `omarchy-install-creative-affinity`, etc.
3. **Power-profile debounce is retired, not re-homed.** The udev rules and
   post-update hook pointed at `~/.local/share/omarchy/bin/omarchy-powerprofiles-set-debounced`,
   which disappears. Under Quattro profile switching moved into Quickshell
   (`shell/plugins/services/battery/Service.qml` watches `UPower.onBatteryChanged`),
   and measurement over a 36% → 90% charge showed **zero unpaired AC-line flaps** —
   the new mechanism does not inherit the AC0 bug. The fix was therefore removed
   rather than re-applied: the machinery is unnecessary, cannot be installed
   anyway (`~/.local/share/omarchy` is now a root-owned symlink), and its
   `RUN+=`-into-user-path pattern is a security liability. See
   `docs/z13-power-profile-churn-fix.md`.
4. **Hibernation patches** — the upgrade overwrites
   `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` and re-normalises limine.
   Re-verify resume end-to-end.
5. **Affinity menu integration** — `~/.config/omarchy/extensions/menu.sh` is the
   old mechanism; Quattro uses `omarchy-menu.jsonc`.
6. **Waybar config is retired** — the bar becomes `~/.config/omarchy/shell.json`.
7. **This repo's `install.sh`** phases 3, 4, 19 write to `hyprland.conf` and
   `~/.local/share/omarchy/bin/` — invalid post-upgrade.

## Upgrade sequence

1. `Update > Omarchy` (get to latest 3.8.x first)
2. `Update > Omarchy to Quattro` (or `omarchy upgrade to quattro --channel edge`)
3. Reboot
4. Verify: desktop loads, network works, `cat /sys/kernel/sched_ext/state`

## Post-upgrade rework order

1. Port Hyprland config to `.lua`:
   - `monitors.lua` (eDP-1), `autostart.lua` (iio-hyprland, rog-profile-notify)
   - `input.lua` (tablet), `bindings.lua` (wvkbd, ROG keys)
   - `looknfeel.lua` (windowrules)
   **Done** — as a single module, `~/.config/hypr/z13.lua`, required from
   `hyprland.lua` (Phase 4). Two findings shaped it:
   - `hyprctl keyword` is rejected by the Lua parser ("keyword can't work with
     non-legacy parsers. Use eval."). This broke `iio-hyprland` until it was
     rebuilt from upstream master (see item 11).
   - A Lua callback runs on the compositor thread, so any call that waits on
     Hyprland IPC (`hyprctl`, and so every `omarchy-hyprland-monitor-*` helper)
     deadlocks the compositor. `hl.timer` also does not fire from callbacks.
   - Bind conflicts with Omarchy defaults: `SUPER+V` (universal paste) and
     `SUPER+SHIFT+S` (Google Maps web app) are unbound before rebinding.
   - **Display config lives in Omarchy's `~/.config/hypr/monitors.lua`, not in
     `z13.lua`.** Phase 4 sets the internal panel's default scale to 1.6 (only
     when the file still has Omarchy's stock `"auto"`) and appends the two Z13
     rules. Both the catch-all and the eDP-1 rule read `omarchy_monitor_scale`,
     which is what makes Omarchy's scaling keys work — the keys rewrite that
     variable and reload. A per-output rule in `z13.lua` broke them: Hyprland
     has no field-level merge, so a rule that omits `scale` does not inherit the
     catch-all, it falls back to PPI `"auto"` and the scale silently freezes.
   - The 4K display is pinned to `3840x2160@120` (its EDID prefers 4K@60) at
     scale 1.25, offset to `1600x-728` so its bottom-left corner meets the
     internal panel's bottom-left (internal anchored at `0x0`). The offset is
     static, so changing the internal scale while docked shifts it.
   - **Disabling the internal panel on hotplug was tried and removed.** It drove
     Omarchy's internal-monitor toggle, whose clamshell watcher and modeless
     recovery loop issue `hyprctl reload`s that raced the modeset and froze the
     session on unplug/replug (reproduced with stock Omarchy's own
     `omarchy-hyprland-monitor-internal toggle` too). The panel now stays on;
     Omarchy still disables it by itself in true clamshell (lid shut). This is
     omarchy#7853, still open upstream — see item 13.
2. ~~Re-home the power-profile debounce~~ — **done, by removal.** The bug does
   not exist under Quattro; the retired rules/wrappers/hook were deleted and
   `lib/phase3_hardware.sh` now removes any leftovers. Wi-Fi power save is owned
   by NetworkManager (`wifi.powersave = 2`). See
   `docs/z13-power-profile-churn-fix.md`.
3. Re-verify hibernation (resume hook, logind bypass, limine cmdline)
4. Port Affinity + custom rows into `~/.config/omarchy/extensions/omarchy-menu.jsonc`
5. Rebuild the bar in `~/.config/omarchy/shell.json`
6. Update `install.sh` phases 3/4/19 for the new paths
7. Re-enable `scx.service` only if you decided to keep it (currently: no)
8. Remove stale NetworkManager configs left by the gaming-mode installer.
   Quattro retires iwd and systemd-networkd, but the old gaming-mode installer
   wrote these when either was active, and they break networking afterwards:
   - `/etc/NetworkManager/conf.d/10-iwd-backend.conf` — points NM at the
     removed iwd backend, killing Wi-Fi.
   - `/etc/NetworkManager/conf.d/20-unmanaged-systemd.conf` — marks `en*`/`eth*`
     unmanaged, so Thunderbolt dock Ethernet has no manager at all.
   DeckShift (the Phase 6 submodule, `templates/deckshift/`) removes both when
   their backends are inactive, and rewrites `/usr/local/bin/gamescope-nm-stop`
   so it no longer stops NetworkManager or restarts iwd. Re-run Phase 6 after
   the upgrade (`./install.sh`, or `templates/deckshift/deckshift.sh` directly).
 9. Re-run Phase 6 (Gaming Tools). The old `Super_shift_S_release.sh` +
    `gaming-mode-hotfix.sh` pair is retired; Gaming Mode now comes from the
    DeckShift submodule, which wires the keybind into `bindings.lua` (the old
    `gaming-mode.conf` / `bindings.conf` writes are dead on Quattro) and binds
    the side button (`XF86Launch3`) rather than `Super+Shift+S`.
    DeckShift `0.2.2-z13.1` also removes the retired stack's leftover
    `gaming-mode.hook` / `gaming-mode-post-update` / `.pre-hotfix` / stale
    `gaming-mode.conf` on install.
10. If Gaming Mode boots gamescope but never launches Steam (no Big Picture),
    the pre-`0.2.2-z13.1` migration removed `gamescope-session-steam-git` and
    failed to restore it (its `sessions.d/steam` is what sets `CLIENTCMD`).
    Run `./scripts/repair-deckshift-migration.sh` to restore it from the yay
    cache and re-verify.
11. **Auto-rotation — done.** The installed `iio-hyprland-git` (r85, Jan 2026)
    drove rotation through `hyprctl --batch "keyword monitor …"`, which the Lua
    parser rejects. Upstream master switched to `hyprctl eval` with
    `hl.monitor`/`hl.config`; the AUR package tracks master, so a rebuild
    (r93.8f56219) restores rotation. Phase 3 now rebuilds the package when the
    installed binary lacks `hyprctl eval`. `z13.lua` launches a wrapper at
    `~/.local/bin/iio-hyprland` (absolute path — the compositor's PATH puts
    `/usr/bin` first) that only sets `DBUS_FATAL_WARNINGS=0`, because upstream
    calls `dbus_connection_close()` on a shared connection and SIGABRTs on its
    exit paths, tripping Omarchy's crash watcher. Verified live: rotation
    applies, `eDP-1` keeps scale 2.0/position, tablet transform follows, and the
    abort is downgraded to a clean exit 1.
12. **Phase 4 targets `.lua`** (`lib/phase4_hyprland.sh` deploys `z13.lua`,
    sets the `monitors.lua` scale default to 1.6, appends the Z13 monitor
    rules, removes the retired dock helper/toggle *and* the dead pre-Quattro
    `hyprland.conf`, and requires the module from `hyprland.lua`). **Phases
    14/17/19 are retargeted:** all three window rules now live in `z13.lua`
    (Lychee file picker, UnrealEditor, and a ChituManager note), and the phases
    no longer write Hyprland config — Phase 4 overwrites `z13.lua` on every run,
    so anything a phase appended there would be wiped. DeckShift's
    `setup_fcitx_silence` no longer writes the dead `hyprland.conf` (fork
    0.2.2-z13.2); `~/.config/environment.d/` is the only mechanism.
13. **Disabling the internal panel is unsafe on this stack — parked until
    upstream fixes it.** `omarchy-hyprland-monitor-internal off` (and the
    clamshell helper's own `disabled = true` + `hyprctl reload`) races the DRM
    modeset on unplug/replug and freezes the session. Tracked as
    `omacom/omarchy#7853` (open, updated 2026-09-15, now also reporting a
    Hyprland SIGSEGV) and `omacom/omarchy#12152` (open, filed 2026-09-16 against
    Omarchy 4.0.4-1 / Hyprland 0.56.2, DPMS-wake variant). The candidate fix
    `omacom/omarchy#7146` is unmerged. Verified: the installed
    `omarchy-hyprland-monitor-{internal,clamshell,watch}` are byte-identical to
    upstream `quattro` HEAD, with zero commits to those paths since 2026-08-25,
    and Hyprland 0.56.2 is still the latest release. So the panel stays on and
    the displays sit side by side. If the panel could be disabled, the external
    would be the only active output and the scale/offset problem below would
    disappear — that is the real fix, not more Z13 tooling.
14. **The HDMI offset is static.** `1600x-728` is exact at the internal panel's
    1.6 default scale. Scaling the internal panel while docked moves it (a gap
    when scaling up, an overlap — and so a rejected output — when scaling down).
    Accepted for now: the alternative is computing the position from
    `omarchy_monitor_scale`, which is custom tooling, and Omarchy's own fix for
    item 13 removes the need entirely.

## Rollback

- **Boot recovery:** pick a snapshot in the limine menu (`limine-snapper-sync`,
  restore method `replace`). Restores `@` only — pair with the dotfile archive.
- **Config reset:** `omarchy reinstall configs`
- **Full reinstall:** `omarchy reinstall`

## Notes

- `scx-scheds` is not in `omarchy-base.packages`, so Quattro will not reinstall
  it. Keep the package name in the backup notes if you want it back.
- The legacy checkout is preserved at
  `~/.local/share/omarchy.omarchy-upgrade-to-quattro.<timestamp>.bak` — useful
  for diffing your patched scripts against upstream.
