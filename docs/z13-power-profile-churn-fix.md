# Z13 Power-Profile / Wi-Fi Power-Save Churn Fix

## Date

2026-09-15

## Problem

The ROG Flow Z13 generated spurious `power_supply` udev events that drove the
power-profile and Wi-Fi power-save rules continuously. Symptoms:

- CPU governor oscillating `performance` <-> `powersave` during work
- asusd rewriting fan curves repeatedly (audible momentary fan stops)
- Notification spam
- Wi-Fi power save toggling at the same rate

## Root cause

`AC0.online` flaps `0 <-> 1` every 1-3 seconds **while the battery is actively
charging**. It is not load-related and not a genuine adapter disconnect.

Independent proof: Omarchy's `wifi-powersave` rule keys on
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

## Fix

### 1. Key the udev rules on the battery, not Mains

`BAT0.status` reflects actual power flow and stays stable while AC0 flaps:

| BAT0.status | Meaning | Action |
|---|---|---|
| `Discharging` | on battery | battery |
| `Charging` | plugged in, charging | AC |
| `Not charging` | plugged in, at charge limit | AC |
| `Full` | plugged in, full | AC |

Both `99-power-profile.rules` and `99-wifi-powersave.rules` now match
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

`omarchy-powerprofiles-set-debounced` (v7) and `z13-wifi-powersave-auto` now
poll until two consecutive readings agree, **restarting** the window on a
mismatch and retrying on unrecognised values, with a bounded timeout. A
mid-transition start converges on the settled state instead of bailing out.

### 3. Wi-Fi power save uses a wrapper, not status matching

Matching `ATTR{status}=="Discharging"` directly in the udev rule has the same
race. A single `KERNEL=="BAT*"` rule now fires `z13-wifi-powersave-auto`, which
reads the settled status itself and applies `on`/`off`.

### 4. No fixed `--unit` names

`BAT0` emits several uevents per transition (observed: two per replug). A fixed
`--unit=` name makes every invocation after the first fail with "unit already
exists". Both rules now let systemd-run generate unique unit names.

### 5. Removed the 10s cooldown

It could block a genuine quick replug and leave stale state, while adding
nothing: the atomic `mkdir` sentinel collapses event bursts, and the idempotency
check already suppresses redundant `powerprofilesctl` calls. The charge-limit
toggle between `Charging` and `Not charging` maps to the same action, so it is
idempotent too.

## Validation

Charge cycle 23:58:57 -> 00:02:57 (4 min), battery 79% -> 90%, on AC throughout.

| Signal | Pre-fix baseline | After fix |
|---|---|---|
| AC0 toggles | ~101 / 14 min | **0 / 4 min** |
| Profile changes | oscillating | **1** (unplug->plug) |
| Governor changes | oscillating | **1** |
| Debounce invocations | 205 / 14 min | **2** |
| Wi-Fi power-save runs | 101 / 14 min | **1** |

Observed transitions (all genuine):

```
23:57:11  profile performance->balanced, governor performance->powersave   (unplug)
23:58:56  bat_status Discharging->Not charging
23:58:58  bat_status Not charging->Charging
23:58:59  profile balanced->performance, governor powersave->performance   (replug)
00:02:57  bat_status Charging->Not charging                                 (hit 90% limit)
```

AC0 read `1` for the entire charge window: 210 consecutive samples, zero flaps.

Reproduce with:

```bash
./scripts/z13-power-validate.sh start   # unplug, replug, charge
./scripts/z13-power-validate.sh status
./scripts/z13-power-validate.sh stop
```

## Files

| File | Role |
|---|---|
| `templates/omarchy-powerprofiles-set-debounced` | v7 wrapper (wait-for-stability) |
| `templates/z13-wifi-powersave-auto.sh` | Wi-Fi power-save wrapper |
| `templates/99-power-profile.rules` | Battery-keyed profile rule |
| `templates/99-wifi-powersave.rules` | Battery-keyed Wi-Fi rule |
| `templates/z13-power-profile-debounce-hook.sh` | Post-update hook, re-applies both |
| `scripts/z13-power-validate.sh` | Validation monitor |

The post-update hook re-keys both rules if an Omarchy update restores the
Mains-based originals. Its pattern checks inspect only lines beginning with
`SUBSYSTEM`, never comments -- the rules carry explanatory comments that mention
the very patterns being searched for, which otherwise caused false positives and
rewrote correct rules on every update.

## Quattro note

After the Omarchy Quattro upgrade, `~/.local/share/omarchy` becomes a symlink to
`/usr/share/omarchy`. The wrapper resolves its target at runtime (legacy path,
then `/usr/bin/omarchy-powerprofiles-set`), but the udev rule paths and the
script's own install location need updating. See
`docs/omarchy-quattro-upgrade-checklist.md`.
