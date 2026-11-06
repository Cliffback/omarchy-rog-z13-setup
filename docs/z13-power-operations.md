# Z13 Power-Profile Operations and Continuation Notes

**Read this first when resuming Z13 power work.** It is the operating sheet for
the debounced profile wrapper and the health timer: current behaviour, paths,
commands, test seams, known gaps, and the branch state at the time of writing.

Bug history, measurements, and the argument for the design live in
[docs/z13-power-profile-churn-fix.md](z13-power-profile-churn-fix.md). This page
does not repeat them.

Snapshot: **2026-11-06**, on top of commit `688a61c` (`z13-power-observability`).

## 1. Behaviour at a glance

The wrapper is `~/.local/bin/omarchy-powerprofiles-set`, installed from
`templates/omarchy-powerprofiles-set-debounced`. It keys on `BAT0.status`
(actual power flow), not `UPower.onBattery`.

| Call | Settle window | Burst guard |
|---|---|---|
| `ac\|battery <profile>`, `autodetect <profile>` | none — applies immediately | bypassed |
| automatic `ac` | 4 agreeing reads (~3 s) | not applied |
| automatic `battery`, ≤1 automatic call in 180 s | 4 agreeing reads (~3 s) | not applied |
| automatic `battery`, ≥2 automatic calls in 180 s | 10 agreeing reads, max 14 (~9 s) | applied |
| `autodetect` with no profile (session init) | 4 agreeing reads | not applied |

"Automatic" means the shell's battery service passed `ac` or `battery` with no
profile argument. The guard counts wrapper invocations, not EC edges (see
[Known residuals](#9-known-residuals)).

A window that never settles changes nothing and logs the sampled readings. An
explicit pick skips both windows so the power panel, menu, and DeckShift stay
responsive mid-flap.

## 2. Wrapper internals

- **Sentinel** (`$XDG_RUNTIME_DIR/z13-powerprofiles.processing`, a directory):
  `mkdir` deduplicates concurrent calls. A holder older than 30 s is reclaimed;
  a held sentinel is logged with its owner and the call exits 0. The `owner`
  file records `pid`, `parent_pid`, `parent`, `since`.
- **Events file** (`$XDG_RUNTIME_DIR/z13-powerprofiles.events`): one epoch per
  automatic call, trimmed to `BURST_WINDOW` and rewritten atomically
  (`tmp` + `mv`). The sentinel makes this a single-writer file. If the runtime
  dir is unwritable, the wrapper degrades to the normal window.
- **Settle loop**: polls `detect_action` every `INTERVAL`; a mismatch restarts
  the agreeing window; an unrecognised reading also restarts it. Gives up after
  `max` samples.
- **Idempotency**: reads `~/.local/state/omarchy/powerprofiles/<ac|battery>`
  (falling back to `performance` for ac when available, else `balanced`) and
  compares with `platform_profile` (`quiet` maps to `power-saver`). Equal means
  no call.
- **Apply**: `run_orig` invokes the packaged script as a child — never `exec`,
  because `exec` skips the `EXIT` trap and leaks the sentinel.
- **Logging**: `logger -t z13-powerprofiles`; `Z13_POWER_LOG` redirects to a
  file for tests.

| Constant | Value | Meaning |
|---|---|---|
| `STABLE_READS` | 4 | normal agreeing reads |
| `MAX_SAMPLES` | 10 | normal sample cap |
| `BURST_WINDOW` | 180 s | how far back an automatic call arms the guard |
| `BURST_STABLE_READS` | 10 | guarded battery agreeing reads |
| `BURST_MAX_SAMPLES` | 14 | guarded sample cap |
| `INTERVAL` | 1 s (`Z13_SETTLE_INTERVAL`) | poll interval |

Log lines worth grepping (kept stable):

```
settled on <ac|battery>; applying <profile>
settled on <ac|battery>; profile already <profile>
burst guard: <n> events in 180s; requiring 10 reads
applied: action=<ac|battery> profile=<profile> rc=<n>
leaving profile unchanged
power source did not settle after <n> samples (readings: ...)
skipped: sentinel held age=<n>s owner=...
reclaiming stale sentinel age=<n>s owner=...
```

## 3. Health check

`~/.local/bin/z13-power-health`, installed from `scripts/z13-power-health.sh`,
run by `z13-power-health.timer` (user unit: first run 2 min after login, then
every 5 min, ±30 s). Report-only; `--fix` is manual on purpose so a regression
stays visible.

| Check | Warning key | Fails when |
|---|---|---|
| wrapper installed / on PATH | `wrapper` | missing, `z13.lua` lost the `~/.local/bin` prepend, or 7 days of AC events with no wrapper lines |
| sentinel age | `sentinel` | `z13-powerprofiles.processing` older than 60 s |
| profile vs state file | `divergence` | mismatch on 2 consecutive runs that began near power activity (otherwise logged once as `override(...)`) |
| flap rate | `flaps` | more than 120 AC-off edges in the last hour |
| burst beat the guard | `burst` | `bursts_1h > 0` **and** `blips_1h > 0` |

Counts (last hour): `flaps_1h`, `changes_1h`, `blips_1h`, `bursts_1h`,
`skipped_1h`. `bursts_1h` groups AC-off edges with ≤30 s between consecutive
edges, at least three per group. A blip is a down/up pair of `settled …;
applying` lines within 10 s.

Modes: `run` (default; log + notify), `status`, `--json`, `--fix`, `--help`.
Exit: 0 healthy, 1 warning, 2 usage. Notifications are rate-limited to one per
hour per key; state is in `~/.local/state/z13-power-health/`.

`--json` fields: `status source profile expected wrapper sentinel divergence
flaps_1h changes_1h blips_1h bursts_1h skipped_1h warnings`.

The service exits 1 on a warning, so `systemctl --user --failed` shows it until
a clean run. A warning based on the sliding hour stays until the underlying
journal events age out.

## 4. Files and live paths

| Repo file | Live path |
|---|---|
| `templates/omarchy-powerprofiles-set-debounced` | `~/.local/bin/omarchy-powerprofiles-set` |
| `scripts/z13-power-health.sh` | `~/.local/bin/z13-power-health` |
| `templates/systemd/user/z13-power-health.service` | `~/.config/systemd/user/z13-power-health.service` |
| `templates/systemd/user/z13-power-health.timer` | `~/.config/systemd/user/z13-power-health.timer` |
| `templates/hypr/z13.lua` | `~/.config/hypr/z13.lua` (prepends `~/.local/bin`) |

Runtime and state:

```
~/.local/state/omarchy/powerprofiles/{ac,battery}   desired profile per source
~/.local/state/z13-power-health/                    divergence counter, notified-* stamps
$XDG_RUNTIME_DIR/z13-powerprofiles.processing       wrapper sentinel (+ owner file)
$XDG_RUNTIME_DIR/z13-powerprofiles.events           automatic-call epochs (3 min)
```

## 5. Command cookbook

```bash
# Health snapshot (no notification)
~/.local/bin/z13-power-health status
~/.local/bin/z13-power-health --json

# What the timer runs (logs one summary line, may notify), and the manual repair
~/.local/bin/z13-power-health run
~/.local/bin/z13-power-health --fix

# Wrapper / health / EC journals
journalctl -b -t z13-powerprofiles -n 30 --no-pager
journalctl -b -t z13-power-health -n 5 --no-pager
journalctl -b -t asusd -o short-unix --no-pager \
  | grep 'External power supply state changed'

# Actual vs desired
cat /sys/firmware/acpi/platform_profile
cat /sys/class/power_supply/AC0/online
cat /sys/class/power_supply/BAT0/status
cat ~/.local/state/omarchy/powerprofiles/ac
cat ~/.local/state/omarchy/powerprofiles/battery

# Wrapper bookkeeping
ls -lad "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/z13-powerprofiles.processing"
cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/z13-powerprofiles.events" 2>/dev/null

# Charge-cycle validation
scripts/z13-power-validate.sh start
scripts/z13-power-validate.sh status
scripts/z13-power-validate.sh stop
scripts/z13-power-validate.sh loadtest 300
```

Use sysfs or `busctl net.hadess.PowerProfiles`, **never `powerprofilesctl get`**:
it is a PyGObject script and a CPython 3.14 shutdown race can SIGSEGV it.

## 6. Iterating safely from a worktree

Work in `~/worktrees/omarchy-rog-z13-setup/z13-power-observability`, not the
canonical checkout. Deploy with:

```bash
W=~/worktrees/omarchy-rog-z13-setup/z13-power-observability
install -m 0755 "$W/templates/omarchy-powerprofiles-set-debounced" \
  ~/.local/bin/omarchy-powerprofiles-set
install -m 0755 "$W/scripts/z13-power-health.sh" \
  ~/.local/bin/z13-power-health
```

Only if the units changed:

```bash
install -m 0644 "$W/templates/systemd/user/z13-power-health."{service,timer} \
  ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now z13-power-health.timer
```

Run both suites before deploying:

```bash
"$W/scripts/test-z13-power-profiles-wrapper.sh"   # ~60 s, 33 checks
"$W/scripts/test-z13-power-health.sh"             # <1 s, 31 checks
```

Live smoke test on AC (profile must not change):

```bash
~/.local/bin/omarchy-powerprofiles-set ac     # settles in ~3 s
```

That call records one automatic event. Delete
`$XDG_RUNTIME_DIR/z13-powerprofiles.events` afterwards if you do not want it to
count toward the next battery switch. To exercise the guard without touching
the profile, seed a recent epoch and call `battery` while on AC; it takes ~9 s
and logs `burst guard: ... requiring 10 reads`.

## 7. Test seams

Wrapper: `Z13_ORIG_SCRIPT`, `Z13_POWER_SUPPLY_ROOT`, `Z13_PLATFORM_PROFILE`,
`Z13_PROFILES_AVAILABLE`, `Z13_POWER_LOG`, `Z13_SETTLE_INTERVAL`,
`OMARCHY_POWERPROFILES_STATE_DIR`, `XDG_RUNTIME_DIR`, `HOME`.

Health adds: `Z13_POWER_HEALTH_STATE_DIR`, `Z13_HEALTH_LOG`, `Z13_NOTIFY_CMD`,
`Z13_SETTLE_SLEEP`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`. `Z13_POWER_LOG` also
puts the health check in fixture-journal mode.

## 8. Decision guide

| Symptom | First check | Lever |
|---|---|---|
| brief quiet blips continue | `blips_1h`, `bursts_1h`, `burst guard:` lines | raise `BURST_STABLE_READS` (e.g. 12) or `BURST_WINDOW`; do not auto-heal |
| every unplug feels slow | `burst guard:` frequency | lower `BURST_STABLE_READS`; ac restores are already 4 reads |
| flaps exceed 120/h | supply and load | 200 W stock adapter; a 140 W SlimQ is the storm trigger |
| profile stuck off the state file | `divergence` + state files | repair the state file, `--fix`, or an explicit pick |
| wrapper never logs | `wrapper=shadowed` | fix the `z13.lua` PATH prepend, `omarchy-restart-shell` |
| sentinel present for minutes | owner file | `z13-power-health --fix`, or `rm -rf` then an explicit pick |

## 9. Known residuals

1. **The first burst after 3 quiet minutes can still blip once.** That call is
   the only event in the window, so it uses 4 reads; subsequent calls inside
   3 minutes arm the guard. One blip per episode, not four.
2. **A guarded battery call that then sees AC return settles `ac` after ~9 s.**
   The profile was usually never changed, so this is a slow no-op, not a
   visible switch. `ac` calls themselves stay at ~3 s.
3. **Events count invocations, not EC edges.** Calls dropped by the sentinel are
   not recorded, so a long settle under-represents edges.
4. **`bursts_1h` and `blips_1h` overlap over a full hour**, so an unrelated
   burst and blip can pair and raise `burst`. Alerting only needs "did anything
   get through", so this is accepted.
5. **The health window is a sliding hour.** A pre-fix incident keeps `[burst]`
   (and the failed unit) visible until its events age out.
6. **`run` exits 1 on any warning**, by design; the unit stays failed until a
   clean run.

## 10. Test coverage

Wrapper (33 checks): 1 s and 2 s flaps, genuine unplug, guarded 5 s run (no
settle), guarded 12 s run (settles after ~10 reads), quiet 5 s run (4 reads),
ac restore during a burst, expired event, 1 Hz storm, explicit pick, held
sentinel, stale sentinel, usage-error cleanup.

Health (31 checks): healthy AC and battery, stale sentinel plus notification
cooldown, two-run divergence, manual override, lost PATH prepend, shadowed
wrapper, storm threshold, blip pairing, burst counted as one group, burst
without a blip (silent), burst with a blip (warns under `burst`), `--fix`.

## 11. Branch and merge snapshot

As of 2026-11-06:

| Ref | State |
|---|---|
| `main` (`bdb6432`) | 3 commits ahead of `origin/main`, not pushed |
| `fix-z13-profile-sentinel` (`d313adc`) | sentinel `exec` fix; unmerged |
| `z13-power-observability` | `d313adc` + hardening (`1847eb8`) + burst guard (`688a61c`) + docs; unmerged, deployed live |

Worktree: `~/worktrees/omarchy-rog-z13-setup/z13-power-observability`.

Merge order when asked (never push or commit to `main` unprompted):

```bash
wt -C ~/code/omarchy-rog-z13-setup merge fix-z13-profile-sentinel
wt -C ~/code/omarchy-rog-z13-setup merge z13-power-observability
```

## 12. See also

- [docs/z13-power-profile-churn-fix.md](z13-power-profile-churn-fix.md) — cause,
  history, measurements, design rationale, debugging table.
- `AGENTS.md` — local agent guide (gitignored, canonical checkout only; it is
  not present in a fresh worktree, which is why this file exists).
