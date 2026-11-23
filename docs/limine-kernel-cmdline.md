# Limine kernel command line: `=` vs `+=`

## The rule

`limine-entry-tool` (run by `limine-mkinitcpio`) builds `KERNEL_CMDLINE[default]`
from its config files in this order (`load_config` in
`/usr/lib/limine/limine-common-functions`):

1. `/usr/share/limine-entry-tool.d/*.conf`
2. `/etc/limine-entry-tool.conf`
3. `/etc/limine-entry-tool.d/*.conf` (drop-ins: Omarchy's, `resume.conf`, this repo's)
4. `/etc/default/limine`, **last**

In any of them:

| Line | Effect |
| --- | --- |
| `KERNEL_CMDLINE[default]+=" foo=1"` | Adds `foo=1` to what is already there. |
| `KERNEL_CMDLINE[default]=" foo=1"` | **Replaces** everything loaded before it. |

A plain `=` in `/etc/default/limine` therefore throws away every drop-in, and
nothing warns about it. On this machine that disabled, until 2026-11-23:

- Omarchy's defaults (`loglevel=0`, `initramfs_async=0`,
  `systemd.tty.term.console=dumb`, ...)
- `rtc_cmos.use_acpi_alarm=1` (`rtc-alarm.conf`, from `omarchy-hibernation-setup`)
- Phase 13's `gpiolib_acpi.ignore_interrupt=...`
- `resume=` / `resume_offset=` (`resume.conf`), so a hibernation image could not be found at boot

Each value carries its own leading space (`+=" foo=1"`). Parameters that end
up repeated are harmless when the values match.

## Check it

No sudo, writes nothing. Prints exactly what the next `limine-mkinitcpio`
will bake in:

```bash
/usr/lib/limine/limine-entry-tool --get-cmdline linux
grep -nE '^\s*KERNEL_CMDLINE\[default\]\s*=' /etc/default/limine   # any hit = drop-ins are being discarded
```

After a rebuild (`sudo limine-mkinitcpio`) and a reboot, compare with
`/proc/cmdline`. `/boot/limine.conf` also holds snapshot entries
(`limine-snapper-sync`); those keep the command line they were created with,
which is expected.

## In this repo

`lib/common.sh` provides:

- `ensure_limine_dropins_effective`: detects the plain `=`, offers to change
  it to `+=` (backup first), and makes the phase stop if you decline.
- `write_limine_dropin`: writes one-line drop-ins.
- `rebuild_limine_and_verify <params...>`: runs `limine-mkinitcpio`, treats
  `mkinitcpio failed for kernel` as a failure even when it exits 0, then
  confirms each parameter is in `--get-cmdline`.

Phases 13, 20 and 21 use them. Put parameters in a drop-in; do not edit the
main line in `/etc/default/limine`.
