# Z13 Power-Profile / Wi-Fi Power-Save Churn Fix

## Status: RESOLVED — machinery retired under Omarchy 4 (Quattro)

This document records a fix that was **removed on 2026-09-16**. It is kept
because the root-cause analysis is still the definitive explanation of the
`AC0.online` flapping behaviour, and because the retired machinery must not be
reintroduced.

- **Omarchy 3 (2025-09-15):** the bug was real; the battery-keyed udev fix
  worked and was validated.
- **Omarchy 4 / Quattro (2026-09-16):** profile switching moved out of udev and
  into Quickshell. The new mechanism does **not** inherit the flap. The fix was
  removed. See [Outcome under Quattro](#outcome-under-quattro).

## Problem (Omarchy 3)

The ROG Flow Z13 generated spurious `power_supply` udev events that drove the
power-profile and Wi-Fi power-save rules continuously. Symptoms:

- CPU governor oscillating `performance` <-> `powersave` during work
- asusd rewriting fan curves repeatedly (audible momentary fan stops)
- Notification spam
- Wi-Fi power save toggling at the same rate

## Root cause

`AC0.online` flaps `0 <-> 1` every 1-3 seconds **while the battery is actively
charging**. It is not load-related and not a genuine adapter disconnect.

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

## Outcome under Quattro

### What changed

Omarchy 4 deleted the power-profile udev rules entirely and moved profile
switching into Quickshell:

- `shell/plugins/services/battery/Service.qml` watches `UPower.onBatteryChanged`
  and calls `omarchy-powerprofiles-set` (no explicit profile, so it never writes
  the state file).
- `shell/plugins/panels/power/Panel.qml` and `shell/plugins/menu/Menu.qml` pass
  an explicit profile when the user picks one, which also records it in
  `~/.local/state/omarchy/powerprofiles/{ac,battery}`.

`UPower.onBattery` is derived from the same AC line power that flaps, so the
question was whether the new mechanism inherits the bug.

### Measurement (2026-09-16)

Charge cycle 09:05:45 -> 09:51:15 (45m30s), battery 36% -> 90%, on AC.

| Signal | Count | Notes |
|---|---|---|
| AC0 transitions | 1 | plug-in only (0 -> 1) |
| UPower.onBattery transitions | 1 | plug-in only (true -> false) |
| **Unpaired AC-line flaps** | **0** | every AC0/UPower move was matched by a BAT0.status change |
| Profile changes | 3 | 1 plug-in + 2 DeckShift restore writes |
| Governor changes | 3 | same three moments |
| asusd fan-curve writes | 8 | 4 at plug-in, 2 per restore write |

Compare the pre-fix baseline: **205 debounce invocations and 101 wifi-powersave
runs in 14 minutes**. Under Quattro there is no churn at all.

The two extra profile changes (`performance -> balanced` at 09:17:04 and
`balanced -> performance` at 09:37:55) were **not** driven by AC0/UPower — those
signals did not move at those moments. They came from DeckShift's
`set_power_profile()` (`templates/deckshift/deckshift.sh`), which deliberately
calls `omarchy-powerprofiles-set autodetect <profile>` so the chosen profile is
recorded for the current power source and survives the next
`omarchy-powerprofiles-init`. That is correct Gaming Mode behaviour, not a bug,
and it does not recur outside Gaming Mode.

### Why the machinery was removed

1. **It is unnecessary.** The flap does not drive profile changes under Quattro.
2. **It is actively broken.** `~/.local/share/omarchy` is now a symlink to
   root-owned `/usr/share/omarchy`, so `omarchy-powerprofiles-set-debounced`
   cannot be installed there. A re-installed `99-power-profile.rules` fails on
   every battery event:
   ```
   (udev-worker): BAT0: Process '.../omarchy-powerprofiles-set-debounced' failed with exit code 1.
   ```
3. **It is a security liability.** The old rule used `RUN+=` pointing into a
   user-writable path under `~/.local/share/omarchy` (root-executes-user-code).
   Omarchy's own migration `1788102906.sh` quarantines such rules for that
   reason. Re-creating one is a regression.

### What remains

- Wi-Fi power save is owned by NetworkManager, pinned off via
  `/etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf` (`wifi.powersave = 2`).
  No udev rule, no wrapper.
- `lib/phase3_hardware.sh` no longer installs anything for this; it **removes**
  any legacy rules/wrappers/hook it finds, so re-running the repo cleans up a
  machine that still carries the old fix.
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

## Files (retired)

| File | Role | Status |
|---|---|---|
| `templates/omarchy-powerprofiles-set-debounced` | v7 wrapper (wait-for-stability) | deleted |
| `templates/z13-wifi-powersave-auto.sh` | Wi-Fi power-save wrapper | deleted |
| `templates/99-power-profile.rules` | Battery-keyed profile rule | deleted |
| `templates/99-wifi-powersave.rules` | Battery-keyed Wi-Fi rule | deleted |
| `templates/z13-power-profile-debounce-hook.sh` | Post-update hook, re-applied both | deleted |
| `scripts/z13-power-validate.sh` | Validation monitor | kept (still useful) |

The post-update hook used to re-key both rules if an Omarchy update restored the
Mains-based originals. Its pattern checks inspected only lines beginning with
`SUBSYSTEM`, never comments -- the rules carried explanatory comments that
mention the very patterns being searched for, which otherwise caused false
positives and rewrote correct rules on every update. This is moot now that the
rules are gone.
