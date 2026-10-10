# pacman repo layout (Omarchy + CachyOS)

Customized `/etc/pacman.conf` ordering, chosen to reduce package drift between
Omarchy and the rolling CachyOS/Arch repos. Full backup: `templates/pacman.conf`.

## Order

```
[omarchy]  ->  [cachyos-znver4] [cachyos-core-znver4] [cachyos-extra-znver4]
           ->  [cachyos] [core] [extra] [multilib] [g14]
```

pacman picks the **first** repo in `pacman.conf` that carries a package, so
putting `[omarchy]` first makes Omarchy's pinned builds win over the
CachyOS/Arch copies for the ~30 overlapping packages — e.g. `quickshell`,
`limine-mkinitcpio-hook`, `limine-snapper-sync`, `nvidia-580xx-*`,
`xpadneo-dkms`, `ghostty`.

Why: on a rolling base, CachyOS/Arch lead Omarchy, so letting Omarchy's own
builds win keeps its vetted support packages (especially `quickshell`, which
Arch/CachyOS build differently) in place. Applied 2026-10-10; after it,
`quickshell` moved `0.3.2-1.1` (cachyos) -> `0.3.2-3` (omarchy).

Channel: **edge** (pinned deliberately — stable/rc lag Arch and the omarchy
repo does not ship `quickshell` on those channels).

## Caveat: `omarchy refresh pacman` and `omarchy channel set`

Both overwrite `/etc/pacman.conf` **wholesale** with a stock template that has
no CachyOS repos, then run `pacman -Syyuu` (downgrades allowed). After such a
run, re-add the CachyOS + g14 repos and move `[omarchy]` first.

Recovery: `refresh-pacman` writes `/etc/pacman.conf.bak` first —
`sudo cp /etc/pacman.conf.bak /etc/pacman.conf`, or restore the repo block from
`templates/pacman.conf`.

Optional automation (not installed — kept simple on purpose): the supported hook
`~/.config/omarchy/hooks/pre-refresh-pacman.d/` runs after the template copy and
before the upgrade. See the packaged `add-custom-repo.sample` there.

## CachyOS kernel as the Limine default

`/boot/limine.conf`:

```
default_entry: Omarchy/linux-cachyos
```

Path form (uses entry titles), so it survives kernel entry renumbering. Set
2026-10-10. Note: `omarchy refresh limine` resets this file to the template
(`default_entry: 2`); re-apply after if you ever run it.
