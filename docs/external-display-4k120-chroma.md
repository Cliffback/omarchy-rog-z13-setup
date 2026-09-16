# External 4K@120 falls back to YCbCr 4:2:0 (chroma subsampling)

## Date

2026-09-16

## Problem

After pinning the external LG C2 to `3840x2160@120` (instead of its EDID-preferred
4K@60), the TV looked "duller and less vibrant" than before — flatter highlights
and contrast than the internal panel. The suspicion was a colour-profile change
(ICC / Hyprland colour management) or a bandwidth problem.

## Verdict

Not a colour-profile regression. The 120 Hz mode negotiates **YCbCr 4:2:0**
(half the chroma resolution) because 4K@120 4:4:4 does not fit the link. At
4K@60 the link carries **RGB 4:4:4**, which is why the picture looked richer
before.

## Evidence

### Link format per mode (`/sys/kernel/debug/dri/1/state`)

| Mode | `output_format` | Chroma | `output_bpc` | `is_limited_range` |
|------|-----------------|--------|--------------|--------------------|
| 3840x2160@60  | RGB   | 4:4:4 | 8 | n |
| 3840x2160@120 | YCbCr | 4:2:0 | 8 | n |

### Colour pipeline is clean

- Every DRM `colorop[...]` on both outputs is `bypass=1`; `color_mgmt_changed=0`.
- Hyprland reports identical colour settings on both outputs:
  `colorManagementPreset: srgb`, `sdrBrightness: 1`, `sdrSaturation: 1`,
  `currentFormat: XRGB8888`.
- No ICC/ICM profiles installed, `colord` inactive, `hyprsunset` not running.
- The `color-encoding=ITU-R BT.709 YCbCr` / `limited range` values on the planes
  are DRM defaults (`color_mgmt_changed=0`), not applied — the internal panel
  shows the same.

### Bandwidth budget

The HDMI port is **not native HDMI**: the APU drives a DisplayPort→HDMI protocol
converter (`dmesg`: `DP-HDMI FRL PCON supported`). The DP side is DP 1.4 HBR3,
effective **~25.9 Gbps**.

| Mode | Format | ~Gbps (with blanking) | Fits? |
|------|--------|-----------------------|-------|
| 4K@120 | 4:4:4 8b | 25.1 | no (no headroom) |
| 4K@120 | 4:2:0 8b | 12.5 | yes — what we get |
| 4K@100 | 4:4:4 8b | 20.9 | yes |
| 4K@60  | 4:4:4 8b | 12.5 | yes |
| 4K@60  | 4:4:4 10b | 15.7 | yes |
| 1440p@120 | 4:4:4 8b | 11.2 | yes |
| 4K@120 | 4:4:4 10b | 26.1 | no |

DSC cannot help: the C2 advertises VESA DSC 1.2a, but **Aquamarine has no DSC
support** (no `dsc`/`compression` symbols in `libaquamarine.so.14`), so 4:4:4
cannot be squeezed into 4K@120.

The C2's EDID lists VIC 118 (4K@120) only inside the **YCbCr 4:2:0 capability
map**, and its max TMDS character rate is 600 MHz — 4K@120 4:4:4 depends
entirely on FRL, which the DP-PCON path cannot deliver with headroom.

## Workarounds

Hyprland exposes `bitdepth` on the monitor rule but **no range/format override**,
so the mode choice is the only lever:

- **4K@100 4:4:4** — best compromise: near-120 Hz smoothness with full colour.
- **4K@60 4:4:4** — guaranteed full colour, lower refresh.
- **1440p@120 4:4:4** — 120 Hz with full colour, lower resolution.

TV-side: enable **HDMI Deep Color**, use **PC mode**, and set the C2's **Black
Level** to match the GPU range. PC mode + 4:4:4 passthrough fixed an earlier
black-crush at 60 Hz (a range mismatch, separate from the chroma issue).

## Current configuration

`templates/hypr/z13.lua` pins the external to `3840x2160@120` (YCbCr 4:2:0). The
tradeoff was accepted for now: 120 Hz smoothness over full chroma. Revisit if
colour fidelity matters more than refresh rate.
