# Hibernation on the Z13

## Status

**Works.** Verified 2026-11-23 on GZ302EA, BIOS 314 (2026-07-20),
linux-cachyos 7.3.4-1, systemd 262.2, Limine + UKI, LUKS (`encrypt` hook) on
btrfs, 128 GB RAM. Five consecutive `systemctl hibernate` runs wrote an image,
powered off and restored the session after the LUKS passphrase (four with
`HibernateMode=platform`, the default, and one with `shutdown`). On
2026-11-24 a platform-mode hibernate hung at power-off, so Phase 25 now sets
`shutdown`; see [Power-off hang](#power-off-hang-platform-s4).

Requirements, all handled by the installer:

| Piece | Where | Phase |
| --- | --- | --- |
| Swapfile ≥ RAM in a btrfs `/swap` subvolume | `omarchy-hibernation-setup` | 21 |
| `resume` initramfs hook | `/etc/mkinitcpio.conf.d/omarchy_resume.conf` | 21 |
| `resume=` + `resume_offset=` on the command line | `/etc/limine-entry-tool.d/resume.conf` | 21 |
| No plain `KERNEL_CMDLINE[default]=` in `/etc/default/limine` | see [limine-kernel-cmdline.md](limine-kernel-cmdline.md) | 13/20/21 guard |
| MT7925 Wi-Fi unloaded across hibernate | `/usr/lib/systemd/system-sleep/mt7925-hibernate` | 22 |
| Keyboard backlight saved/restored | `/usr/lib/systemd/system-sleep/keyboard-backlight` | 23 |
| LLMs unloaded first | `z13-llm-unload.service` | 24 |
| `HibernateMode=shutdown` (power off via S5) | `/etc/systemd/sleep.conf.d/z13-hibernate-mode.conf` | 25 |
| Lid close: suspend, hibernate after 15 min | `/etc/systemd/logind.conf.d/30-z13-lid-hibernate.conf`, `/etc/systemd/sleep.conf.d/z13-hibernate-delay.conf` | 26 |
| Critical battery hibernates | `/etc/UPower/UPower.conf.d/70-z13-critical-hibernate.conf` | 26 |

## What a hibernate looks like

`systemctl hibernate` → image written (tens of seconds; the image is up to 2/5
of RAM) → **machine powers off** → press power → Limine menu → LUKS passphrase
prompt (Plymouth, the same one as every boot) → the initramfs restores the
image → session is back, usually behind the lock screen.

The passphrase prompt is easy to mistake for a normal boot. The swapfile is
inside the encrypted root, so a real resume can never skip it.

## Telling a real resume from a rolled-back attempt

A failed attempt and a successful resume look almost the same in the kernel
log. Both show the snapshot, `ACPI: PM: Waking up from system sleep state S4`,
`Basic memory bitmaps freed` and `hibernation exit`. The image-write messages
are lost on a real resume (they were printed by the kernel whose memory was
thrown away), and `PM: Image restored successfully` only prints with
`/sys/power/pm_debug_messages` set. Use these instead. None needs root.

1. **Monotonic vs wall time.** systemd measures the unit with the monotonic
   clock, which does not run while the machine is off:

   ```bash
   journalctl -b -o short-precise | grep -E "Performing sleep operation 'hibernate'|System returned from sleep|systemd-hibernate.service: Consumed"
   ```

   A real resume: ~74 s between "Performing" and "returned", but `Consumed ...
   over 7.7s wall clock time`. A kernel that kept running would have counted
   the whole time.

2. **`HibernateLocation` removed.** systemd writes this EFI variable before
   hibernating. Only `systemd-hibernate-resume` in the boot initramfs (called
   by the mkinitcpio `resume` hook) deletes it. After a real resume the kernel
   logs `efivarfs: removing variable HibernateLocation-...`.

3. **Firmware and Limine ran again.** Limine rewrites its timing variables on
   every boot. If they differ from the `Startup finished in ... (firmware) +
   ... (loader)` line logged at the original boot, the machine went through
   firmware since then:

   ```bash
   journalctl -b | grep -m1 'Startup finished in .*firmware'
   for v in LoaderTimeInitUSec LoaderTimeExecUSec; do
     tail -c +5 /sys/firmware/efi/efivars/$v-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\0'; echo
   done   # Init = firmware time, Exec - Init = loader time, in µs
   ```

Supporting signs: every USB root hub logs `root hub lost power or was reset`,
and device firmware (MT7925, CS35L41 amplifiers) reloads.

### Traps

- **`journalctl -k -o short-monotonic` timestamps are wrong across
  hibernation.** journald is frozen, so a whole attempt is received in about
  20 ms after resume and timestamped then. Do not compute durations from them.
  `dmesg` has the real printk times (needs root).
- **The boot ID does not change.** `boot_id` is kernel memory and is restored
  with the image, so "one boot ID throughout" does not mean the machine never
  rebooted.
- **Swap shows 0 B used after resume.** The image is not counted as used swap,
  and the kernel invalidates it on resume.

## Power-off hang (platform S4)

**Symptom (2026-11-24 22:14).** `systemctl hibernate`, the screen goes black,
and the machine never reaches a state the power button can wake. Holding the
power button forces it off. The next power-on goes through Limine and LUKS, and
the session resumes. The image was complete, so the hang came **after** the
image write, in the final power-off. That kernel's messages are lost (see Traps).

**What was different.** With `HibernateMode=platform` (systemd's default), the
kernel finishes through the firmware's ACPI S4 entry (`_PTS`, EC stop, SLP_TYP
S4). With `shutdown`, it calls the normal power-off (S5). The kernel log of the
snapshot phase shows which path ran:

```bash
journalctl -b -k | grep -E "hibernation entry|Preparing to enter system sleep state S4|hibernation exit"
# an "S4" line between entry and exit = platform mode
```

| Run | Mode | Result |
| --- | --- | --- |
| 11-23 09:35, 09:43, 09:49, 09:56 | platform | OK |
| 11-23 10:02 | shutdown | OK |
| 11-24 15:52 | (ENOMEM, LLM loaded) | rolled back |
| 11-24 15:54–18:50 | s2idle suspend in the same kernel | OK |
| 11-24 22:14 | platform | **hung at power-off** |

The hung run was the first S4 after an s2idle cycle in that kernel's lifetime.
The hooks, asusd and the MT7925 unload behaved as in the good runs. One failure
is not proof. Omarchy's own `keyboard-backlight` hook, though, exists because "the
ASUS keyboard controller can block S4 shutdown", and S5 is the path every normal
shutdown takes. Last winter, "the next hibernate after a good one fails" was
seen and never diagnosed. This may be the same thing.

**Fix:** Phase 25, `/etc/systemd/sleep.conf.d/z13-hibernate-mode.conf`:
`HibernateMode=shutdown`. systemd-sleep reads it on every run, so it needs no
reload. Check it with `systemd-analyze cat-config systemd/sleep.conf`.

Validated 2026-11-25 after a reboot: three hibernates in shutdown mode, one
straight after an s2idle suspend (the sequence that hung). All three powered off,
woke on the power button and really resumed (no `S4` line, `HibernateLocation`
removed, ~9 s monotonic against a ~2.5 min gap).

**If it happens again:** a hard power-off is safe once the screen is black,
because the image is already on disk and the next boot resumes it. Then check the
kernel log for the S4 line above. If shutdown mode hangs too, the ACPI S4 path is
ruled out. The next suspects are the detachable keyboard (test with it unplugged)
and amd_pmc state after s2idle, bisected with `/sys/power/pm_test`.

## Lid close and low battery

| Situation | What happens (Phase 26) |
| --- | --- |
| Lid closed, battery or AC | Suspend; hibernate after 15 min, or earlier below 5% battery |
| Lid closed, docked / external display | Nothing (`HandleLidSwitchDocked=ignore`) |
| Suspend from the menu (`systemctl suspend`) | Plain suspend, no later hibernate |
| Battery reaches 5% while awake | UPower hibernates (warning at 8%) |

**Why:** a closed-lid s2idle suspend on 2026-11-24 drained the battery from
~53% to 27% in under 3 hours (about 8–9%/h). UPower is frozen during suspend, so
a plain suspend never reacts to a low battery: the machine runs flat and the
session is lost. Before Phase 26, UPower's `CriticalPowerAction=Auto` resolved
to logind's `Sleep` (via `SleepOperation=`) at 2%.

**What a lid close looks like:** `systemd-suspend-then-hibernate.service`
suspends, an RTC alarm wakes the machine after `HibernateDelaySec=`, and it then
hibernates. Open the lid within 15 minutes and it wakes instantly; later, it
comes back through Limine and the LUKS prompt. Sleep hooks are called once
per step with `SYSTEMD_SLEEP_ACTION` set to `suspend`, then `hibernate`, so
`mt7925-sleep` and `kbd-backlight-sleep` log a `pre suspend`/`post suspend` pair
followed by `pre hibernate`/`post hibernate`.

```bash
journalctl -b -u systemd-suspend-then-hibernate.service
journalctl -b -t mt7925-sleep -t kbd-backlight-sleep -t z13-llm-unload
```

To test without waiting, temporarily set `HibernateDelaySec=2min` in
`/etc/systemd/sleep.conf.d/z13-hibernate-delay.conf` (read on every sleep; no
reload needed).

**Open question:** 8–9%/h is high for s2idle on Strix Halo and suggests the
SoC does not reach its deepest state. `/sys/kernel/debug/amd_pmc/s0ix_stats`
(root) and `amd_s2idle.py` from the kernel tree would show it; not yet checked.

## MT7925 Wi-Fi

Without the hook, restore logs:

```
mt7925e 0000:c2:00.0: Message 00020015 (seq N) timeout
ieee80211 phyN: PM: dpm_run_callback(): wiphy_resume [cfg80211] returns -110
```

The resume itself completes, but Wi-Fi is dead until `mt7925e` is reloaded.
The hook unloads the module in `pre` and loads it in `post`:

```bash
journalctl -b -t mt7925-sleep   # pre hibernate: loaded=1 / after pre: loaded=0 / post hibernate: loaded=1
journalctl -k -b | grep -E '00020015|wiphy_resume'   # expect nothing after the hook went in
```

- **systemd 262 reads hooks only from `/usr/lib/systemd/system-sleep/`.** A
  copy in `/etc/systemd/system-sleep/` never runs (`strings
  /usr/lib/systemd/systemd-sleep | grep system-sleep` lists only the `/usr/lib`
  path).
- Unloading normally takes ~3 s, but up to ~65 s if the MCU is already wedged
  from an earlier failed resume.

## Keyboard backlight

Omarchy's `/usr/lib/systemd/system-sleep/keyboard-backlight` sets every
`*kbd_backlight*` LED to 0 before hibernate (a lit ASUS keyboard can block S4
power-off) and has no `post` branch, so the backlight is off after every
resume. It is also off after a hibernate that never happened: seen 2026-11-24,
`Failed to put system to sleep. System resumed again: Cannot allocate memory`
(`Image allocation is ... pages short`) left `asus::kbd_backlight` at 0.

Phase 23 replaces that hook at the same path with
`templates/keyboard-backlight-sleep`, which saves each level to
`/run/z13-kbd-backlight/` before zeroing and writes it back on `post` (retrying
for up to 5 s while the keyboard re-enumerates). It must be one hook: hooks
run in parallel, so a separate save hook would race Omarchy's turn-off.
Logs: `journalctl -b -t kbd-backlight-sleep`. If an Omarchy update reinstalls
its version, Phase 23's check fails and a re-run restores ours.

## Loaded LLMs (Cannot allocate memory)

Hibernation copies every in-use page into free RAM before writing the image,
so in-use memory has to fit in roughly half of RAM. GPU memory on Strix Halo is
system RAM and cannot be swapped out first. Seen 2026-11-24 with llama-swap
holding a model:

```
gpu_active:81383584kB                       (~78 GB, in the kernel's Mem-Info dump)
PM: hibernation: Image allocation is 8381632 pages short   (~32 GB)
systemd-sleep: Failed to put system to sleep. System resumed again: Cannot allocate memory
```

The swapfile size is irrelevant (121 GB, empty). The successful 2026-11-23
hibernate needed 12.6M pages with 19.8M available.

Phase 24 installs `z13-llm-unload.service`, wanted by `hibernate.target` and
ordered before `systemd-hibernate.service`, so it runs before systemd-sleep
freezes `user.slice` (llama-swap is a user unit). It calls llama-swap's
`/unload` and Ollama's `keep_alive: 0`, waits up to 20 s for both to report
nothing loaded, and logs GTT use before/after under
`journalctl -b -t z13-llm-unload`. A sleep hook would be too late: hooks run
after the freeze. It is also wanted by `suspend-then-hibernate.target`, so a
lid close unloads models up front: the later hibernate step never passes
through `hibernate.target`.

## Tested dead ends

- `options mt7925e disable_aspm=1`: no change to the MT7925 timeout.
- BIOS/firmware hunt and `pm_test` bisecting: not needed. The "failure" was
  a misread log (see Traps).

## Known side effects

- **CS35L41 right amplifier.** Once in five resumes,
  `cs35l41-hda.1: Failed waiting for OTP_BOOT_DONE` /
  `cs35l41_system_resume ... returns -121`. It recovered by itself on the next
  audio runtime-resume (firmware reloaded about 6 min later). If the right
  speaker stays silent, play a sound or run `systemctl --user restart pipewire`.

## Tuning (untested)

`/sys/power/image_size` defaults to 2/5 of RAM (~48.6 GB here), so images of
28–48 GB were written. A smaller target (e.g. 16 GB) makes the kernel drop
caches first: less to write and read, so faster hibernate and resume. It has to
stay below the swap size, or `omarchy-hibernation-available` hides the menu
entry. Make it persistent with a tmpfiles.d `w /sys/power/image_size` line.
Time it before adopting.

## Useful commands

```bash
omarchy-hibernation-available && echo ok
tr ' ' '\n' </proc/cmdline | grep resume
cat /sys/power/resume /sys/power/resume_offset /sys/power/disk
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile   # must equal resume_offset
/usr/lib/limine/limine-entry-tool --get-cmdline linux        # what the next build bakes
journalctl -b -u systemd-hibernate.service
```

History: [hibernation-unified-memory-investigation.md](hibernation-unified-memory-investigation.md)
(March 2026, swap smaller than `image_size`, which hid the menu entry).
