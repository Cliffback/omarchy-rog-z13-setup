# AMD display freeze (DMCUB crash)

## Symptom

The internal panel goes dark or freezes and stops responding to input, but the
machine is otherwise fine: SSH works, Hyprland and the shell are still running,
and there is no memory, CPU or IO pressure. `hyprctl monitors` shows
`dpmsStatus: 0` for `eDP-1` even though nothing asked for the display to stay
off.

## Cause

DMCUB is the display microcontroller inside the Strix Halo GPU. It handles the
panel's power-saving transitions: PSR (panel self refresh), Panel Replay, and
IPS (idle power states). When it crashes during one of those transitions, the
kernel logs it and the panel never comes back on its own.

Signatures seen on this machine:

```
2026-11-20 09:52  WARNING: .../display/dc/dc_dmub_srv.c:1698 at dc_dmub_srv_apply_idle_power_optimizations
2026-11-22 20:10  amdgpu 0000:c4:00.0: [drm] *ERROR* dc_dmub_srv_log_diagnostic_data: DMCUB error - collecting diagnostic data
```

Neither occurrence was preceded by anything unusual in the journal. Kernel
7.3.4-1-cachyos, `linux-firmware-amdgpu 1:20261019-1`. The 44 boots in the
journal back to 2026-09-01 show nothing earlier.

Find occurrences:

```bash
journalctl -k --no-pager -o short-iso -g 'DMCUB|dc_dmub_srv|flip_done' | grep -v UFW
```

## Recover without rebooting

From SSH, or anything else that can reach the session:

```bash
hyprctl dispatch 'hl.dsp.dpms("on")'
hyprctl monitors | grep dpmsStatus   # expect 1
```

Omarchy 4 uses the Lua dispatcher syntax. The old `hyprctl dispatch dpms on`
fails with `')' expected near 'on'`.

If the panel stays black after that, switch to a text console and back at the
machine (`Ctrl+Alt+F3`, then `Ctrl+Alt+F1`/`F2`), then restart the session.

## Fix: `amdgpu.dcdebugmask`

Phase 20 writes the parameter to its own drop-in,
`/etc/limine-entry-tool.d/amdgpu-display.conf`, then runs `limine-mkinitcpio`
and checks that the parameter is in the pending command line. The parameter is
read-only at runtime (`/sys/module/amdgpu/parameters/dcdebugmask` is `0444`),
so it needs a reboot.

The first version of this fix edited `/etc/default/limine`, because a plain
`KERNEL_CMDLINE[default]="..."` there was discarding every drop-in. The shared
guard now turns that `=` into `+=` instead (see
[limine-kernel-cmdline.md](limine-kernel-cmdline.md)). Phase 20 also moves a
mask left in `/etc/default/limine` into the drop-in, so there is one source.

Manual equivalent:

```bash
echo 'KERNEL_CMDLINE[default]+=" amdgpu.dcdebugmask=0x410"' | sudo tee /etc/limine-entry-tool.d/amdgpu-display.conf
/usr/lib/limine/limine-entry-tool --get-cmdline linux | grep -o 'amdgpu.dcdebugmask=[^ ]*'
sudo limine-mkinitcpio
systemctl reboot
```

| Bit     | Flag                | Effect                                   |
| ------- | ------------------- | ---------------------------------------- |
| `0x10`  | `DC_DISABLE_PSR`    | Disable PSR and PSR-SU                   |
| `0x400` | `DC_DISABLE_REPLAY` | Disable Panel Replay                     |
| `0x800` | `DC_DISABLE_IPS`    | Disable all IPS (except during suspend)  |

- **`0x410` (default):** PSR and Panel Replay off. Small battery cost on a
  static screen. This is the common community workaround for DMCUB freezes on
  recent AMD laptops.
- **`0xC10` (escalation):** also disables IPS. Use it if a DMCUB error recurs
  with `0x410` active. The Nov 20 warning was in the IPS path
  (`apply_idle_power_optimizations`), so this is the next suspect. It costs
  noticeably more idle power.

```bash
Z13_DCDEBUGMASK=0xC10 ./install.sh   # re-runs Phase 20 with the wider mask
```

Verify after reboot:

```bash
grep -o 'amdgpu.dcdebugmask=[^ ]*' /proc/cmdline
cat /sys/module/amdgpu/parameters/dcdebugmask   # decimal: 0x410 = 1040, 0xC10 = 3088
```

Revisit when `linux-firmware-amdgpu` (DMCUB firmware) or the kernel's DC code
changes: remove `/etc/limine-entry-tool.d/amdgpu-display.conf`, run `sudo limine-mkinitcpio`, and reboot to test
whether the mask is still needed.

## Sources

- [Kernel docs: DC debug flags](https://www.kernel.org/doc/html/latest/gpu/amdgpu/display/dc-debug.html)
- [CachyOS: amdgpu fails to enable replay and hangs (`0x410`)](https://discuss.cachyos.org/t/amdgpu-fails-to-enable-replay-psr2-and-hangs-after-login/19975)
- [Framework: FW16 screen freezing (DMCUB errors, `0x10`)](https://community.frame.work/t/fw16-screen-freezeing-on-linux/73958)
