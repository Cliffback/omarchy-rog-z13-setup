# Z13 (GZ302EA): custom fan curves and the fan-2 pin

## Status

On the ROG Flow Z13 GZ302EA with BIOS `GZ302EA.314`, an asusd **custom** fan
curve was observed to pin the second fan (`gpu_fan`) at roughly 6300–6400 RPM
regardless of temperature or load (2026-11-04/05). The EC's own per-profile table
is fine.

A controlled re-test on 2026-11-05 at 45–50 °C did **not** reproduce the pin:
every curve combination stayed at 0–3700 RPM. The 6300 reading is still the
reason the repo leaves the custom curves disabled (Phase 2b), but the pin is not
deterministic under warm-idle conditions. `scripts/z13-fan-curve-probe.sh` is the
authoritative check.

This is a firmware/EC + asusd interaction, not a kernel, Hyprland or Omarchy bug.

## Hardware and software

| Item | Value |
|---|---|
| Model | ASUS ROG Flow Z13 (2025), `GZ302EA` |
| BIOS | `GZ302EA.314` |
| EC | 3.8 |
| Kernel | `7.3.0-5-cachyos` |
| Omarchy | 4.5.0rc1 |
| asusctl | 6.5.0-1 |

The EC version is the one recorded when the fan pin was first measured; re-read
it after a BIOS/EC update and re-run the probe.

## Symptom (original observation)

`asusctl fan-curve --mod-profile Quiet --enable-fan-curves true` (or the same
write asusd performs on a profile change) made fan 2 jump to ~6300 RPM and stay
there. The machine was otherwise idle: about 36 °C package temperature and
12–18 W package power. Note that 36 °C is consistent with the fan itself running
at full speed; it is an effect of the pin, not a precondition for it.

Disabling the curves immediately returned the fans to the firmware's table:
Quiet idled at 0 RPM, and Balanced/Performance returned to their own tables
(0 RPM in the 10:03–10:04 observation; they ramp with temperature and load).
Performance reached 4700–5100 RPM under sustained stress.

Controlled re-tests at 45–50 °C (see below) did not reproduce the 6300 pin.

## Measurements

All values are from this machine. `gpu_fan` is `fan2_input` under the hwmon
device named `asus`.

| When | Profile / curve state | Load / temperature | `gpu_fan` |
|---|---|---|---|
| 2026-11-04 23:21:53 | Quiet; asusd writes the Quiet curve, CPU curve enabled | idle | — |
| 2026-11-05 09:54 | Quiet; custom curve enabled | 36 °C, 12–18 W | **6300** |
| 2026-11-05 09:56 | Quiet; GPU curve enabled too | same | **6300** (no change) |
| 2026-11-05 10:03:59 | Balanced; all curves disabled | idle | **0** |
| 2026-11-05 10:04:19 | Performance; all curves disabled | idle | **0** |
| 2026-11-05 (confirmation) | Quiet; all curves disabled | 45 °C, idle | **0** |
| 2026-10-10 (fanprobe) | Performance; all curves disabled | `stress-ng`, sustained | **4700–5100** |

The `2026-11-05 10:13` file state confirms the fix persisted: all six entries in
`/etc/asusd/fan_curves.ron` are `enabled: false`, and the pre-fix backup shows
Quiet CPU+GPU were `true`.

## Reproduction status (2026-11-05)

The original 6300 RPM reading was at 36 °C. Controlled re-tests on the same
machine, using the real `asusctl` toggles, could not reproduce it:

| Test | CPU / GPU temp | `cpu_fan` | `gpu_fan` |
|---|---|---|---|
| Curves off (firmware Quiet) | 45 °C | 0 | 0 |
| Both curves on, direct toggle | 48–50 °C | 3400–3500 | **3700** |
| Both curves on, Balanced → Quiet cycle | 50 °C | 3400 | **3600** |
| CPU curve only (the 09:54 state) | 47 °C | 0–3500 | **0–2800** |
| GPU curve only | 47 °C | 0 | **0** |
| Curves off, display off for 5 min | 45–46 °C | 0–2300 | **0–2700** |
| Both curves on after the cooldown | 47–50 °C | 0–3200 | **2700–3700** |

A 15 W TDP retest was not possible: idle package power was already 11.7 W and
the asusd tuning interface refused a manual change ("profile tuning is disabled
for current profile and power state"). The display-off idle bottomed at 45–46 °C,
not 36 °C.

So the pin is real in the 2026-11-04/05 observation but is not reliably
reproducible at warm idle. It may depend on the exact EC state at the time (for
example, a low-temperature or post-resume path). The probe below settles it for
the current machine state.

## Test matrix

| Profile | Custom curves | Idle fan behaviour | Under load |
|---|---|---|---|
| Quiet | off | 0 RPM (or 0–2800 RPM depending on temperature) | firmware Quiet table (low/silent) |
| Quiet | on (CPU only, then CPU+GPU) | **6300** at 36 °C (historical); **0–3700** at 45–50 °C (re-test) | not reliably reproducible |
| Balanced | off | 0 RPM at cool idle; ramps with temperature | firmware Balanced table |
| Performance | off | firmware table (0 RPM at cool idle) | 4700–5100 RPM under sustained stress |
| custom | empty by default | — | user-managed; Phase 2b leaves it alone |

## What the measurements show

- **The firmware table is fine.** Quiet with curves off is 0 RPM at 45 °C;
  Balanced and Performance return to their own tables (0 RPM in the 10:03–10:04
  observation; they ramp with temperature and load). Performance reached
  4700–5100 RPM under sustained stress.
- **The original pin was not load-related.** It was recorded at 36 °C and
  12–18 W, with the fan itself providing the cooling that held 36 °C.
- **The pin is not deterministic.** Re-tests at 45–50 °C with both curves, CPU
  only, or GPU only stayed at 0–3700 RPM. The 2026-11-04/05 state may have
  depended on the exact EC state (e.g. a cold-start or post-resume path).
- **In the historical observation it was not GPU-specific.** The first reading
  had the CPU curve enabled; enabling the GPU curve afterwards changed nothing.
  That does not prove the re-test behaves the same way.

## Reproduce

The standalone probe toggles the active profile's curves off → on → off, samples
`fan2_input` by hwmon name (never by index), and restores the original state on
exit:

```bash
./scripts/z13-fan-curve-probe.sh --dry-run   # show the plan, change nothing
./scripts/z13-fan-curve-probe.sh             # 5 s settle + 15 s per state
```

The raw commands, if you want to see it by hand:

```bash
asusctl profile set Quiet

# Off: expect 0 RPM at cool idle
sudo asusctl fan-curve --mod-profile Quiet --enable-fan-curves false
sleep 15
sensors asus-isa-000a | grep -E 'cpu_fan|gpu_fan'

# On: watch fan 2. If it pins, expect ~6300-6400 RPM; if it does not, 0-4000
sudo asusctl fan-curve --mod-profile Quiet --enable-fan-curves true
sleep 15
sensors asus-isa-000a | grep -E 'cpu_fan|gpu_fan'

# Always restore
sudo asusctl fan-curve --mod-profile Quiet --enable-fan-curves false
```

Run at idle. The probe reports a verdict only when the temperature stays
reasonably flat across the three windows; otherwise the RPM comparison is
confounded. A pin raises fan 2 by more than 1000 RPM; a flat result means the
firmware is still in charge even with the curve enabled.

## Fix / workaround

Phase 2b disables the custom curves for the three firmware profiles:

```bash
for p in Quiet Balanced Performance; do
  sudo asusctl fan-curve --mod-profile "$p" --enable-fan-curves false
done

grep -c 'enabled: true' /etc/asusd/fan_curves.ron   # expect 0
```

This is a conservative default: the firmware's per-profile tables are correct
and the custom curves are not needed. It also prevents the 6300 pin if it returns
on this EC/BIOS state. If the probe shows no pin on your machine, the phase is
harmless but optional.

Use the CLI, not `sed`, on `/etc/asusd/fan_curves.ron`: asusctl updates asusd's
live config and the persisted file together. The `custom` profile is
user-managed and is deliberately not touched.

No reboot is required. After changing a profile with Fn+F5, confirm asusd did
not re-enable a curve:

```bash
asusctl profile set Quiet
sleep 5
grep -c 'enabled: true' /etc/asusd/fan_curves.ron   # still 0
```

Re-run the probe after a BIOS or EC update; do not gate the phase on the
version string.

## If you want a quieter or cooler machine

The working lever is the **TDP cap** (Phase 5, `Super+Shift+Q`), not a custom
fan curve. Lowering the package power limit reduces heat, which lets the
firmware's Quiet table stay at low RPM. Re-enabling a custom curve may recreate
the ~6300 RPM pin.

Rollback (only if you deliberately want the curve back):

```bash
for p in Quiet Balanced Performance; do
  sudo asusctl fan-curve --mod-profile "$p" --enable-fan-curves true
done
```

## Later option: z13ctl-plus

`z13ctl-plus-bin` (AUR 2.5.3-1, updated 2026-11-04) is a fork of `z13ctl` that
claims to preserve Quiet's zero-RPM behaviour. It is **not** adopted here:

- it would replace or compete with asusd, which Phase 2, the N-KEY
  `aura_18c6.ron` brightness fix, `asusd.ron`'s charge limit/EPP and Fn+F5
  notifications all depend on;
- Phase 5's TDP writes go through `asus-nb-wmi`, so the interaction needs its own
  validation;
- the firmware Quiet table is fine once the custom curves are off, and the pin
  is not reliably reproducible, so it does not yet justify a daemon replacement.

If the firmware Quiet table ever turns out to be broken too (Quiet with curves
off still loud), or the pin becomes reproducible and z13ctl-plus demonstrably
avoids it, evaluate z13ctl-plus as its own phase-sized change.

## Gotchas

- `asusctl profile list` prints `Quiet Balanced Performance` (capitalised).
  `--mod-profile` is case-insensitive.
- `asusctl fan-curve --get-enabled` reports the **active** profile; it cannot
  inspect a named one. Use `grep 'enabled: true' /etc/asusd/fan_curves.ron` to
  inspect all profiles at once.
- `asusctl fan-curve --mod-profile <name>` with no other options prints that
  profile's table, including each fan's `enabled:` field. That is the clean way
  to inspect one profile.
