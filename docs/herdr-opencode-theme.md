# Herdr, OpenCode, and the Catppuccin Mocha palette

Why restored OpenCode panes look grey after a reboot, why Omarchy's bundled
Catppuccin theme does not look like upstream Catppuccin, and what Phases 20–21
do about it.

## The boot race

Omarchy starts `herdr server` from `default/hypr/autostart.lua` at login so
panes inherit `WAYLAND_DISPLAY`. Herdr then restores the saved session and
resumes agent panes. It waits only 750 ms for a client to supply the host
terminal palette (`PENDING_AGENT_RESUME_THEME_WAIT`); with no client attached it
starts the agents with `host_terminal_theme` empty.

OpenCode's `theme: system` resolves the terminal foreground, background, and
16-colour palette **when the TUI starts**, then caches the generated theme.
The restored TUIs therefore read Herdr's fallback palette, not the user's
Catppuccin/Tokyo Night palette. They keep that palette until OpenCode re-reads
the terminal colours.

OpenCode 2.x re-reads them on `SIGUSR2` (and on a `?997` light/dark report).
Herdr sends `?997` only when the host appearance transitions dark↔light, not
on the first `None → Dark` attach, so the restored TUIs never refreshed
themselves.

## The ANSI mapping

Omarchy's bundled `catppuccin` theme is Catppuccin Mocha, but the generated
terminal configs map ANSI colours from semantic keys:

```text
palette 0 = background      # 1e1e2e
palette 7 = foreground      # cdd6f4
palette 8 = muted           # 585b70
palette 15 = bright_foreground
```

Upstream Catppuccin Mocha defines:

| ANSI | Upstream |
|---|---|
| 0 black | `#45475a` surface0 |
| 7 white | `#bac2de` subtext1 |
| 8 bright black | `#585b70` surface2 |
| 15 bright white | `#a6adc8` subtext0 |
| cursor | `#f5e0dc` rosewater |

So ANSI black becomes the background (invisible), ANSI white becomes the main
text colour, and any app using the 16-colour palette looks wrong. This is
tracked as omarchy#12520.

## The refresh bug

Omarchy's `omarchy-restart-opencode` is supposed to send `SIGUSR2` to OpenCode
after every theme change:

```bash
if pgrep -x opencode >/dev/null; then
  killall -SIGUSR2 opencode
fi
```

OpenCode 2 installed by mise runs as `opencode.exe`, so `pgrep -x opencode`
never matches and the refresh never happens. A naive `killall` against
`opencode.exe` would also hit the shared `opencode serve --service` process,
which does not handle `SIGUSR2` and would terminate. See omarchy#17374 and the
fix in #17438.

## What the phases do

**Phase 20 — Herdr terminal integration**

- `[theme] name = "terminal"` makes Herdr's chrome follow the terminal palette.
- `[theme.custom] surface_dim = "darkgray"` keeps pane dividers visible; the
  shipped `"black"` is ANSI 0, which Omarchy maps to the background
  (omarchy#15235).
- `opencode-refresh-theme` sends `SIGUSR2` only to `opencode --session ses_…`
  TUIs that have a `SIGUSR2` handler (`SigCgt` bit `0x800`). It never matches
  `serve`.
- `herdr-attach` waits two seconds after `exec herdr`, then runs the refresh.
- A user-level `~/.local/bin/omarchy-launch-terminal-herdr` shadows Omarchy's
  launcher, so the stock `SUPER+CTRL+RETURN` binding uses the wrapper.
  `~/.local/bin` precedes `$OMARCHY_PATH/bin` because `hypr/z13.lua` prepends
  it.
- `prefix+shift+t` inside Herdr runs the refresh manually.

**Phase 21 — Catppuccin Mocha theme**

- Deploys `~/.config/omarchy/themes/catppuccin-mocha` as a plain directory.
  Omarchy strips terminal configs from git-installed themes; a plain directory
  is treated as user-authored and keeps them.
- Ships `ghostty.conf`, `alacritty.toml`, `foot.ini`, and `kitty.conf` with the
  official ANSI palette, and `colors.toml` with the Mocha desktop/bar palette.
- Applies the theme with `omarchy theme set catppuccin-mocha`.
- Copies wallpapers and menu previews from the stock Catppuccin theme at deploy
  time, so no binary assets live in this repository.
- Runs `opencode-refresh-theme` after applying, so the currently running TUIs
  pick up the new palette immediately when a Herdr client is attached.

Herdr 0.9.1 may need one detach/reattach to notice the new host palette; 0.9.2+
re-reads host colours on `SIGWINCH`.

## Validate

```bash
# Herdr is following the terminal and the divider workaround is present.
herdr server reload-config
grep -A2 '^\[theme\]' ~/.config/herdr/config.toml
grep -A3 '^\[theme.custom\]' ~/.config/herdr/config.toml

# The deployed theme kept the official palette.
grep 'palette = 0' ~/.config/omarchy/themes/catppuccin-mocha/ghostty.conf
cat ~/.local/state/omarchy/current/theme.name

# The refresh helper only touches TUIs.
~/.local/bin/opencode-refresh-theme
```

## Upstream references

- omarchy#12520 — terminal ANSI black/muted contrast under dark themes
- omarchy#15235 — Herdr dividers invisible with `surface_dim = "black"`
- omarchy#17374 — `omarchy-restart-opencode` misses mise's `opencode.exe`
- omarchy#17438 — proposed fix for the `.exe` refresh
- omarchy#6812 — make terminal applications follow Omarchy themes (Herdr)
- omarchy#15350 — sync Omarchy themes to OpenCode 2 without OS signals
