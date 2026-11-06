# Catppuccin Mocha (Z13 setup)

Catppuccin Mocha for Omarchy with the official Catppuccin terminal palette.

This directory is deployed by `install.sh` Phase 21 to
`~/.config/omarchy/themes/catppuccin-mocha`. It is a plain directory, not a git
checkout, because Omarchy strips `ghostty.conf`, `alacritty.toml`, `foot.ini`,
and `kitty.conf` from themes installed as git repositories. Those files are the
whole point: they replace Omarchy's generated ANSI mapping:

| ANSI | Omarchy default | Official Catppuccin Mocha |
|---|---|---|
| 0 black | background `#1e1e2e` | surface0 `#45475a` |
| 7 white | foreground `#cdd6f4` | subtext1 `#bac2de` |
| 8 bright black | muted `#585b70` | surface2 `#585b70` |
| 15 bright white | bright foreground `#cdd6f4` | subtext0 `#a6adc8` |
| cursor | foreground | rosewater `#f5e0dc` |

See omarchy#12520 for the upstream mapping issue.

## Palette

- background `#1e1e2e`, foreground `#cdd6f4`
- black `#45475a`, bright black `#585b70`
- red `#f38ba8`, green `#a6e3a1`, yellow `#f9e2af`
- blue `#89b4fa`, magenta `#f5c2e7`, cyan `#94e2d5`
- white `#bac2de`, bright white `#a6adc8`
- cursor `#f5e0dc`, selection `#45475a` on `#cdd6f4`
- indexed 16 `#fab387` (peach), 17 `#f5e0dc` (rosewater)

`colors.toml` keeps Omarchy's Mocha desktop/bar palette. The hand-written
terminal configs carry the ANSI palette above.

## Install

Normally installed by the setup script:

```bash
./install.sh
```

Do **not** use `omarchy theme install` for this directory. A theme installed
from a git repository loses its terminal configs, and the ANSI fix with it.
