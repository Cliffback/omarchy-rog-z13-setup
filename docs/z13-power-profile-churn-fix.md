# Z13 Power-Profile / Wi-Fi Power-Save Churn Fix

## Status: mitigated by a user-level wrapper (Omarchy 4.5, 2026-10)

The `AC0.online` flap is a firmware/EC behaviour that was **not** fixed by BIOS
314 (measured 2026-10-09) and cannot be fixed in software. What can be fixed is
the consequence: Omarchy 4's shell turns every flap into a profile switch. The
current fix is a debounced, `BAT0.status`-keyed wrapper around
`omarchy-powerprofiles-set` (see [Current fix](#current-fix)).

History:

- **Omarchy 3 (2025-09-15):** the bug was real; the battery-keyed udev fix
  worked and was validated.
- **Omarchy 4 / Quattro (2026-09-16):** profile switching moved into
  Quickshell. A single charge window showed no flap, the udev machinery was
  retired — and the problem returned. See
  [Recurrence under Quattro](#recurrence-under-quattro).
- **Omarchy 4.5 / 2026-10:** the wrapper replaces an earlier `z13.battery`
  service clone, which forked first-party QML and drifted.

## Problem (Omarchy 3)

The ROG Flow Z13 generated spurious `power_supply` udev events that drove the
power-profile and Wi-Fi power-save rules continuously. Symptoms:

- CPU governor oscillating `performance` <-> `powersave` during work
- asusd rewriting fan curves repeatedly (audible momentary fan stops)
- Notification spam
- Wi-Fi power save toggling at the same rate

## Root cause

`AC0.online` flaps `0 <-> 1` **while the battery is actively charging**. Near
full charge at light load it flaps a few times per few minutes; under heavy load
on an under-rated supply it flaps at ~1 Hz. It is not a genuine adapter
disconnect. (An earlier version of this document called it not load-related;
the 2026-10-10 storm disproved that.)

Independent proof: Omarchy's `wifi-powersave` rule keyed on
`ATTR{type}=="Mains", ATTR{online}`, and it toggled **101 times in 14 minutes**
while battery capacity rose monotonically 53% -> 64%. The adapter was solidly
connected throughout.

### The load-triggered misdiagnosis

An earlier fix (v5) assumed the storm was triggered by CPU load. That was wrong:

| Period | Battery | State | Debounce events |
|---|---|---|---|
| 20:36-20:50 | 53->64% | Charging | 205 in 14 min |
| 21:44-22:20 (32-thread load, 35 min) | 90% | Not charging | 0 |

35 minutes of full 32-thread saturation produced zero events; charging produced
205 in 14 minutes. The original observation coincided with the battery happening
to be charging.

## The Omarchy 3 fix (now removed)

### 1. Key the udev rules on the battery, not Mains

`BAT0.status` reflects actual power flow and stays stable while AC0 flaps:

| BAT0.status | Meaning | Action |
|---|---|---|
| `Discharging` | on battery | battery |
| `Charging` | plugged in, charging | AC |
| `Not charging` | plugged in, at charge limit | AC |
| `Full` | plugged in, full | AC |

Both `99-power-profile.rules` and `99-wifi-powersave.rules` matched
`KERNEL=="BAT*", ATTR{type}=="Battery"`.

`KERNEL=="BAT*"` matches the kernel's system-battery names (BAT0, BAT1, ...) and
excludes peripheral batteries such as the Elan touchpad's
`hid-0018:04F3:43C7.0008-battery-7`.

**Do not use `ATTR{scope}!="Device"` for this.** It was tested and does not work:
BAT0 has no `scope` attribute at all, so the match silently never fires.

### 2. Wait-for-stability, not abort-on-disagreement

The udev event fires **before** `BAT0.status` settles. A guard that requires N
samples to agree and otherwise aborts therefore rejects a *genuine* transition.
This was observed in practice: an unplug read `Not charging` then `Discharging`,
concluded "unstable", and did nothing -- leaving the machine on `performance`
while on battery.

`omarchy-powerprofiles-set-debounced` (v7) and `z13-wifi-powersave-auto` polled
until two consecutive readings agreed, **restarting** the window on a mismatch
and retrying on unrecognised values, with a bounded timeout. A mid-transition
start converges on the settled state instead of bailing out.

### 3. Wi-Fi power save used a wrapper, not status matching

Matching `ATTR{status}=="Discharging"` directly in the udev rule has the same
race. A single `KERNEL=="BAT*"` rule fired `z13-wifi-powersave-auto`, which read
the settled status itself and applied `on`/`off`.

### 4. No fixed `--unit` names

`BAT0` emits several uevents per transition (observed: two per replug). A fixed
`--unit=` name makes every invocation after the first fail with "unit already
exists". Both rules let systemd-run generate unique unit names.

### 5. Removed the 10s cooldown

It could block a genuine quick replug and leave stale state, while adding
nothing: the atomic `mkdir` sentinel collapses event bursts, and the idempotency
check already suppresses redundant `powerprofilesctl` calls. The charge-limit
toggle between `Charging` and `Not charging` maps to the same action, so it is
idempotent too.

## Validation (Omarchy 3 fix)

Charge cycle 23:58:57 -> 00:02:57 (4 min), battery 79% -> 90%, on AC throughout.

| Signal | Pre-fix baseline | After fix |
|---|---|---|
| AC0 toggles | ~101 / 14 min | **0 / 4 min** |
| Profile changes | oscillating | **1** (unplug->plug) |
| Governor changes | oscillating | **1** |
| Debounce invocations | 205 / 14 min | **2** |
| Wi-Fi power-save runs | 101 / 14 min | **1** |

AC0 read `1` for the entire charge window: 210 consecutive samples, zero flaps.

## Recurrence under Quattro

Profile switching moved into Quickshell, but the flap did not go away. The
2026-09-16 measurement was a quiet window, not a fix.

### Measurement (2026-10-09, BIOS 311)

While charging 78% -> 90% with light load, `AC0.online` / `UPower.onBattery`
flapped at 18:23, 18:26, 18:30, 18:31:35, 18:31:48, 18:34:51 and 18:35:08 —
each pair ~2 s apart. Every `false` produced `Setting BalancePower`, every
`true` `Setting Performance`. Nothing flapped once the pack reached the 90%
limit and stopped charging.

### The load-while-charging storm (2026-10-10, BIOS 314)

BIOS 314 did not help. With the battery charging and a sustained CPU+iGPU load
(Lychee / `stress-ng`), `AC0`, `BAT0.status` and `UPower.onBattery` all flipped
at ~1 Hz and the profile cycled `performance <-> balanced` continuously: 25
line-power events and 98 fan-curve writes in one boot. Killing the load stopped
it; a second heavy process (Lychee slicing) brought it back. The supply was a
**140 W SlimQ** barrel adapter; the Z13 ships with **200 W** (20 V / 10 A).
An under-provisioned supply + charging + load is what tips the EC into the
oscillating regime.

### Why 314 did not fix it

BIOS 314 is a security/fleet-maintenance release (AGESA `StrixHaloPI-FP11`
1.0.0.2b, new USB-C PD-controller capsule-update stack). It carries no
EC/adapter-flap fix, and downgrading is not permitted.

## Current fix

A debounced wrapper, `~/.local/bin/omarchy-powerprofiles-set`, installed by
Phase 3 from `templates/omarchy-powerprofiles-set-debounced`:

- keys on **`BAT0.status`** (actual power flow), not `UPower.onBattery`
  (`Discharging` -> battery; `Charging`/`Not charging`/`Full` -> ac);
- waits for two consecutive agreeing readings (bounded timeout), restarting the
  window on a mismatch so a genuine transition still converges;
- if it cannot settle — a sustained storm — it **does nothing**;
- if settled, it reads the `~/.local/state/omarchy/powerprofiles/<ac|battery>`
  state file and skips the call when that profile is already active;
- passes explicit-profile calls through (`ac|battery <profile>`,
  `autodetect <profile>`) so the power panel, menu and DeckShift keep working,
  even if the line is unsettled;
- logs decisions under `logger -t z13-powerprofiles`.

`~/.config/hypr/z13.lua` prepends `~/.local/bin` to the compositor PATH after
Omarchy's `default/hypr/envs.lua` (which puts `$OMARCHY_PATH/bin` first), so the
shell's battery service, session autostart and DeckShift all resolve the
wrapper. No udev rule, no root, no `RUN+=`.

Validate with `scripts/z13-power-validate.sh loadtest [SECONDS]` while plugged
in and charging: **profile changes <= 2** is the pass condition.

### Why the udev machinery stayed retired

1. **No root-executes-user-code.** The old rule used `RUN+=` pointing into a
   user-writable path under `~/.local/share/omarchy`. Omarchy's own migration
   `1788102906.sh` quarantines such rules for that reason. The wrapper needs
   neither.
2. **`~/.local/share/omarchy` is now a root-owned symlink** to
   `/usr/share/omarchy`, so the old wrapper location is not writable and a
   re-installed `99-power-profile.rules` fails on every battery event.
3. **udev is the wrong key.** Keying on the battery in udev still races the
   status transition; the wrapper does the settle check itself.

### Why not a service clone

An earlier fix (`z13.battery`) cloned `omarchy.battery` and debounced inside it.
It worked, but forking a first-party service drifted: Omarchy 4.5 added
`powerSaverOnBattery` to the battery service (and `omarchy.lock` now reads it),
so the clone silently lost behaviour. The wrapper keeps the built-in service.

### What remains

- Wi-Fi power save is owned by NetworkManager, pinned off via
  `/etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf` (`wifi.powersave = 2`).
  No udev rule, no wrapper.
- `lib/phase3_hardware.sh` removes any legacy udev rules/root wrapper/hook, and
  installs/refreshes the wrapper. Re-running the repo cleans up a machine that
  still carries the old fix.
- Use the **200 W stock adapter** for heavy work while charging. A 140 W supply
  is what turns the mild flap into the ~1 Hz storm.
- DeckShift's profile writes are left as-is: they only happen inside Gaming
  Mode.

## Reproduce the measurement

```bash
./scripts/z13-power-validate.sh start   # unplug, replug, charge to the limit
./scripts/z13-power-validate.sh status
./scripts/z13-power-validate.sh stop
```

The verdict keys on **unpaired** AC-line transitions: an AC0/UPower change with
no accompanying `BAT0.status` change. A real plug/unplug moves both; the old bug
toggled AC0 while `BAT0.status` stayed put. That distinction is what makes "the
user plugged in once" read as healthy rather than as churn.

## Files

| File | Role | Status |
|---|---|---|
| `templates/omarchy-powerprofiles-set-debounced` | Debounced BAT0-keyed wrapper, installed to `~/.local/bin/omarchy-powerprofiles-set` | current (Phase 3) |
| `templates/hypr/z13.lua` | Prepends `~/.local/bin` to the compositor PATH | current (Phase 4) |
| `scripts/z13-power-validate.sh` | Validation / load-test monitor | current |
| `templates/99-power-profile.rules` | Battery-keyed udev profile rule | retired (Omarchy 3) |
| `templates/99-wifi-powersave.rules` | Battery-keyed udev Wi-Fi rule | retired |
| `templates/z13-wifi-powersave-auto.sh` | Wi-Fi power-save wrapper | retired |
| `templates/z13-power-profile-debounce-hook.sh` | Post-update udev hook | retired |
| `templates/omarchy-plugins/z13.battery/` | Debounced service clone | retired (drifted in Omarchy 4.5) |
| `templates/omarchy-plugins/z13.lock/` | Patched lock service clone | retired (fixed upstream in 4.0.6) |

The post-update hook is obsolete now that the udev rules are gone. The service
clones were retired for drift: Omarchy 4.5 changed `omarchy.battery` (adding
`powerSaverOnBattery`, which `omarchy.lock` reads) and 4.0.6 fixed the lock
wedge in `omarchy.lock` itself (#14978).
