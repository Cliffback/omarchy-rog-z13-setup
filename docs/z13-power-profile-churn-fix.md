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

Correction (2026-11-05, BIOS 314): the charge limit itself is not quiet. At 89%
with a 90% limit and `BAT0.status = Not charging` (`power_now = 0`), four flaps
landed in 3½ minutes (17:04:07, 17:06:55, 17:06:59, 17:07:24), each 1–2 s. The
EC toggles around the top-off boundary, so "stop charging" does not mean "stop
flapping". This is the regime the four-read settle window is sized for.

### The load-while-charging storm (2026-10-10, BIOS 314)

BIOS 314 did not help. With the battery charging and a sustained CPU+iGPU load
(Lychee / `stress-ng`), `AC0`, `BAT0.status` and `UPower.onBattery` all flipped
at ~1 Hz and the profile cycled `performance <-> balanced` continuously: 25
line-power events and 98 fan-curve writes in one boot. Killing the load stopped
it; a second heavy process (Lychee slicing) brought it back. The supply was a
**140 W SlimQ** barrel adapter; the Z13 ships with **200 W** (20 V / 10 A).
An under-provisioned supply + charging + load is what tips the EC into the
oscillating regime.

### The 21:44 burst (2026-11-05)

Four AC-off edges in 12 s at 21:44:22, then the same pattern at 21:54:25,
21:56:54 and 21:57:24, at 54% and ~72 W into the pack with load ~2.8. Each
burst held `BAT0.status=Discharging` for ~5 s, long enough for the four-read
window to settle: the wrapper applied power-saver and the ac call undid it 5–6 s
later. Four visible down/up pairs in 13 minutes. A fifth burst at 21:49:33
(5 edges / 13 s) never settled and changed nothing.

The control is the genuine battery stint 19:32:50 → 21:42:27: `battery` applied
once at unplug and `ac` once at replug, with no intervening switches. The
difference is the burst, not the four-read window itself.

### Why 314 did not fix it

BIOS 314 is a security/fleet-maintenance release (AGESA `StrixHaloPI-FP11`
1.0.0.2b, new USB-C PD-controller capsule-update stack). It carries no
EC/adapter-flap fix, and downgrading is not permitted.

## Current fix

A debounced wrapper, `~/.local/bin/omarchy-powerprofiles-set`, installed by
Phase 3 from `templates/omarchy-powerprofiles-set-debounced`. Operations,
deployment, test seams, and known residuals are in
[z13-power-operations.md](z13-power-operations.md).

The wrapper:

- keys on **`BAT0.status`** (actual power flow), not `UPower.onBattery`
  (`Discharging` -> battery; `Charging`/`Not charging`/`Full` -> ac);
- waits for four consecutive agreeing readings (~3 s, bounded timeout),
  restarting the window on a mismatch so a genuine transition still converges.
  Two readings were not enough: 1–2 s charge-boundary flaps settled as
  "battery" and applied power-saver for a second or two before the ac call
  undid it (measured 2026-11-05 at 17:04–17:07);
- applies an asymmetric **burst guard**: a battery switch that follows another
  automatic call within 3 minutes must see ten agreeing readings (~9 s)
  instead of four. ac restores keep the four-read window, so a real replug is
  not delayed. This is sized for the 21:44–21:57 bursts above, where a ~5 s
  `Discharging` run under four reads became a visible down/up pair;
- if it cannot settle — a sustained storm — it **does nothing**;
- if settled, it reads the `~/.local/state/omarchy/powerprofiles/<ac|battery>`
  state file and skips the call when that profile is already active;
- applies explicit-profile calls (`ac|battery <profile>`, `autodetect
  <profile>`) immediately, without the settle window, so the power panel, menu
  and DeckShift keep working even if the line is flapping;
- logs every decision and every exit under `logger -t z13-powerprofiles`,
  including dropped calls and the sampled readings of an unsettled window.

`~/.config/hypr/z13.lua` prepends `~/.local/bin` to the compositor PATH after
Omarchy's `default/hypr/envs.lua` (which puts `$OMARCHY_PATH/bin` first), so the
shell's battery service, session autostart and DeckShift all resolve the
wrapper. No udev rule, no root, no `RUN+=`.

Validate with `scripts/z13-power-validate.sh loadtest [SECONDS]` while plugged
in and charging: **profile changes <= 2** is the pass condition.

### The exec/sentinel leak (fixed 2026-11-05)

A single one-second `AC0` blip flipped `BAT0.status` to `Discharging` for long
enough to satisfy the two-sample settle window, so the wrapper applied the
battery profile (`power-saver`, i.e. `platform_profile=quiet`). The matching ac
call was then dropped:

- every apply path ended with `exec "$ORIG_SCRIPT" ...`;
- `exec` replaces the shell, so the `EXIT` trap never ran and
  `$XDG_RUNTIME_DIR/z13-powerprofiles.processing` was left behind;
- the next call within 30 s found that sentinel, judged it not stale, and
  exited 0 **silently** — exactly the call that would have restored
  `performance`.

The machine stayed on quiet until an explicit profile pick 35 s later, which
only got through because the sentinel had aged past the reclaim threshold.

`run_orig` now invokes the original script as a child and the script exits
normally, so the trap always fires. When a profile change seems to be ignored,
check for a leftover sentinel first:

```bash
ls -lad "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/z13-powerprofiles.processing"
```

The same day, at 17:07, a flap outlasted the by-then two-read window and produced
a brief quiet: `power-saver` applied, `performance` restored one second later.
With the fix in place that was cosmetic rather than stuck, but it is why the
settle window is now four reads: the residual blip should not happen at all.

### Monitoring (2026-11-05)

Every failure on this path is silent. A dropped call, a stale sentinel, a stuck
profile, and a shadowed wrapper all look the same from the outside: "it went
quiet again". Two layers make them visible.

**Wrapper audit trail.** `logger -t z13-powerprofiles` records every exit:
`settled on …; profile already …`, `settled on …; applying …`, `applied:
action=… profile=… rc=…`, `skipped: sentinel held age=… owner=…`, the sampled
readings when a window never settles, and stale-sentinel reclamation. A leaked
sentinel names its holder because the sentinel directory carries an `owner` file
(`pid`, `parent_pid`, `parent` command).

**Health timer.** `z13-power-health.timer` (user unit, every 5 min) runs
`~/.local/bin/z13-power-health`. It logs one summary line per run to
`logger -t z13-power-health` and notifies — at most once per hour per check —
when something is wrong. It never repairs by itself; `--fix` is manual so a
regression stays visible.

| Check | Fails when | Meaning |
|---|---|---|
| `wrapper` | missing, `z13.lua` lost the PATH prepend, or AC events in 7 days with no wrapper lines | wrapper shadowed / not resolving |
| `sentinel` | `z13-powerprofiles.processing` older than 60 s | leaked or wedged run |
| `divergence` | profile ≠ state-file mapping on 2 consecutive runs, and the mismatch began next to a power event or wrapper decision | stuck profile (the bug class that matters) |
| `flaps` | more than 120 flaps/h | storm; supply headroom |
| `blips` | recorded, never alerted | a down/up pair within 10 s; the harmless residual |
| `bursts` | `bursts_1h > 0` and `blips_1h > 0` | a cluster of consecutive AC-off edges beat the burst guard |

`bursts_1h` groups AC-off edges with no more than 30 s between consecutive
edges (at least three per group); a burst the guard absorbs stays silent.

A mismatch with no recent power activity is a deliberate manual override: it is
logged once as `override(...)` and never notified. `skipped_1h` is recorded but
not alerted — a skip is the dedupe guard working, not a failure; a real leak is
caught by the sentinel age and the divergence check.

Summary shape:

```
health ok profile=performance expected=performance source=ac sentinel=absent \
  div=ok wrapper=ok flaps_1h=68 changes_1h=1 blips_1h=0 bursts_1h=0 skipped_1h=0 warnings=0
```

`~/.local/bin/z13-power-health status` prints the same data readably, `--json`
for scripts, and `--fix` clears a stale sentinel and re-applies the state-file
profile for the current source.

### Fan-curve writes are cosmetic while the custom curves are off

asusd still logs `write_profile_curve_to_platform` on every AC-line notify. With
the repo's default — custom fan curves disabled (Phase 2b) — the write still
reaches the platform, but with `enabled: false` the EC keeps its own per-profile
table in charge, so the fan effect is cosmetic. A flat fan RPM across an AC
transition is therefore expected and does not mean the write is harmless in
every configuration.

With a custom curve enabled, the same write was observed to pin fan 2 at
~6300 RPM on GZ302EA (BIOS 314); controlled re-tests at 45–50 °C did not
reproduce it. The 2026-10-10 baseline (4700–5100 RPM under stress) was captured
with curves off. See [z13-fan-curve-gz302ea.md](z13-fan-curve-gz302ea.md).

## Debugging

| Tag | Producer | Contains |
|---|---|---|
| `z13-powerprofiles` | wrapper | settle decisions, `applied … rc=`, `skipped: sentinel held …` |
| `z13-power-health` | timer | 5-min summary and warnings |
| `asusd` `ctrl_platform` | asusd | every AC-line edge and the EPP/platform_profile write it triggers |

First 60 seconds:

```bash
cat /sys/firmware/acpi/platform_profile                 # actual
cat /sys/class/power_supply/BAT0/status                 # actual power flow
cat ~/.local/state/omarchy/powerprofiles/{ac,battery}    # desired mapping

journalctl -b -t z13-powerprofiles -n 20 --no-pager
journalctl -b -t z13-power-health -n 5 --no-pager
ls -lad "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/z13-powerprofiles.processing"
cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/z13-powerprofiles.events" 2>/dev/null

journalctl -b --since -1h --no-pager | grep -c 'External power supply state changed'
```

Use the sysfs read, **not** `powerprofilesctl get`: that spawns Python, and
Omarchy avoids it because of a CPython 3.14 shutdown race (python/cpython#124619).

| Symptom | Cause | Check | Fix |
|---|---|---|---|
| Quiet on AC and it stays | ac restore dropped (stale sentinel) | sentinel dir age | `z13-power-health --fix`, or `rm -rf` it then `omarchy-powerprofiles-set ac` |
| A switch does nothing | state file already holds the target (e.g. `battery=performance`) | state files | `omarchy-powerprofiles-set battery balanced` |
| Wrapper never logs | shadowed by the packaged script / PATH lost | no wrapper lines while asusd logs AC edges | fix `~/.config/hypr/z13.lua`, `omarchy-restart-shell` |
| Brief quiet blips | EC burst outlasted the settle window | `blips_1h` with `bursts_1h` | the burst guard absorbs runs up to ~9 s; a longer burst warns under `burst` |
| Fans rev, profile steady | asusd rewrites curves on every AC edge | fan-curve write count | supply headroom; not software-fixable |

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
  installs/refreshes the wrapper, the health check and its user timer. Re-running
  the repo cleans up a machine that still carries the old fix.
- Use the **200 W stock adapter** for heavy work while charging. A 140 W supply
  is what turns the mild flap into the ~1 Hz storm.
- DeckShift's profile writes are left as-is: they only happen inside Gaming
  Mode.
- The health timer is report-only by design. If the flap rate or the blip count
  becomes a nuisance, the next lever is the burst guard's read count
  (`BURST_STABLE_READS`), not auto-healing: `blips_1h` and `bursts_1h` in the
  summary say whether anything still gets through.

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
| `scripts/z13-power-health.sh` | Report-only health check, installed to `~/.local/bin/z13-power-health` | current (Phase 3) |
| `templates/systemd/user/z13-power-health.{service,timer}` | 5-minute user timer for the health check | current (Phase 3) |
| `scripts/z13-power-validate.sh` | Validation / load-test monitor | current |
| `docs/z13-power-operations.md` | Operating sheet: behaviour, paths, commands, seams, residuals, branch state | current |
| `scripts/test-z13-power-profiles-wrapper.sh` | Fixture tests for the wrapper (flap/storm/sentinel) | current |
| `scripts/test-z13-power-health.sh` | Fixture tests for the health check | current |
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
