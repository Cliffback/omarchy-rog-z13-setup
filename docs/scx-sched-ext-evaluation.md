# sched_ext (scx) Evaluation on the ROG Flow Z13

## Date

2026-09-15

## Summary

Tested `scx_lavd` and `scx_bpfland` from the `scx-scheds` package against the
stock EEVDF scheduler. **Conclusion: do not persist a sched_ext scheduler.**
EEVDF is already excellent on this hardware, and the sched_ext schedulers trade
away wake latency under full saturation for a modest process-spawn advantage.

## Hardware / Kernel

- Ryzen AI MAX+ 395 (Strix Halo, Zen 5), 32 threads / 16 cores / 2x32MB L3 / 1 NUMA
- `linux-cachyos` 7.2.2-1, `CONFIG_SCHED_CLASS_EXT=y`
- `scx-scheds` 1.1.3-2

## Method

`scripts/scx-latency.c` measures wake-up latency overshoot over a `nanosleep`
without fork overhead (a naive bash timing loop measures ~4400us of fork cost
and hides the real signal). `scripts/scx-bench.sh` and `scripts/scx-sweep.sh`
run it idle and under load, alongside a parallel-zstd throughput test and a
process-spawn test.

## Findings

### Wake latency under saturation (32-thread tight-loop load)

| Scheduler | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| EEVDF | 53us | 52 | 53 | 63 | 1194 |
| scx_lavd --performance | 934us | 984 | 2406 | 3063 | 4994 |
| scx_bpfland | 409us | 184 | 1002 | 1007 | 2017 |

scx_lavd's worst case (~5000us) matches its `slice_max_us` default, i.e. the
waking task waits for a full scheduling slice.

### The penalty is load-dependent

| Load | EEVDF mean | scx_lavd --performance mean |
|---|---|---|
| 4 threads | 51us | 56us |
| 8 threads | 55us | 55us |
| 16 threads | 52us | 52us |
| 24 threads | 51us | 54us |
| 32 threads | 57us | 956us |

Below full saturation scx_lavd matches EEVDF. The cliff appears only when every
CPU is oversubscribed.

### The synthetic case overstates the problem

With a *realistic* parallel compile (`make -j1` x32 on the kernel tree) instead
of 32 tight-loop threads:

| Scheduler | wake mean | p99 |
|---|---|---|
| EEVDF | 92us | 567us |
| scx_lavd --performance | 143us | 752us |

A 1.5x penalty, not 16x. The tight-loop test is an adversarial worst case.

### scx_lavd does win on process spawn

Consistently reproducible, ~2.9x faster under load:

| Scheduler | 500x spawn under load |
|---|---|
| EEVDF | 0.69s |
| scx_lavd --performance | 0.20s |

Still present in the realistic compile scenario (0.132s vs 0.100s), though much
smaller.

### Tuning does not close the gap

| Config | wake mean | p99 | spawn |
|---|---|---|---|
| EEVDF | 53us | 63 | 0.688s |
| lavd --performance | 893us | 3140 | 0.202s |
| lavd --performance --preempt-shift 3 | 889us | 3006 | 0.228s |
| lavd --performance --preempt-shift 0 | 886us | 3008 | 0.208s |
| lavd --performance --slice-max-us 1000 --pinned-slice-us 0 | 658us | 1017 | 0.200s |
| lavd --balanced | 914us | 3011 | 0.200s |
| lavd --autopower | 887us | 3003 | 0.198s |

Note: `--slice-max-us` below 5000 requires `--pinned-slice-us 0`, otherwise
scx_lavd panics because the pinned-slice default (5000) exceeds the new max.

## Conclusion

EEVDF wins on the metric that matters for interactive use (wake latency under
saturation), and its p99 stays within ~10us of its idle latency even at full
load. scx_lavd's spawn advantage does not compensate.

Do not enable `scx.service`. The package remains installed for future
experimentation; no persistence was configured.

## Environment / Testing Caveat

The Z13 emits spurious `power_supply` events that fired the debounced profile
switcher ~23x/minute, flipping the CPU governor between `performance` and
`powersave` mid-benchmark. This silently invalidated the first round of results.

The trigger is **charging, not load** -- an initial misdiagnosis. 35 minutes of
full 32-thread saturation at 90% charge produced zero events, while charging
produced 205 in 14 minutes. The full investigation and fix are documented in
`docs/z13-power-profile-churn-fix.md`.

The benchmark harness retains a drift monitor: `scx-bench.sh` samples the
profile and governor every 0.5s and records every transition, then marks the run
unstable. `scx-ab-test.sh` refuses to print a comparison if either run drifted.
A start/end comparison alone would miss a transient flip that returns to its
original value.

A `powerprofilesctl launch` hold does **not** help here: an explicit
`powerprofilesctl set` (which the debounce script issues) overrides the hold.

## Reproducing

```bash
./scripts/scx-ab-test.sh scx_lavd --performance   # full A/B
./scripts/scx-sweep.sh                            # wake-latency sweep
./scripts/scx-sweep.sh "lavd-x:scx_lavd --performance --slice-max-us 1000 --pinned-slice-us 0"
```

All require sudo to load schedulers and pin the power profile for the duration.
