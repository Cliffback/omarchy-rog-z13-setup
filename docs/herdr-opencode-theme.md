# Herdr, OpenCode, and the terminal palette

Why restored OpenCode panes look grey after a reboot, what Phase 20 does about
it, and why OpenCode's `system` theme looks flatter than Herdr.

## The boot race

Omarchy starts `herdr server` from `default/hypr/autostart.lua` at login so
panes inherit `WAYLAND_DISPLAY`. Herdr then restores the saved session and
resumes agent panes. It waits only 750 ms for a client to supply the host
terminal palette (`PENDING_AGENT_RESUME_THEME_WAIT`); with no client attached it
starts the agents with `host_terminal_theme` empty.

OpenCode's `theme: system` resolves the terminal foreground, background, and
16-colour palette **when the TUI starts**, then caches the generated theme.
The restored TUIs therefore read Herdr's fallback palette, not the user's
palette. They keep it until OpenCode re-reads the terminal colours.

OpenCode 2.x re-reads them on `SIGUSR2` (and on a `?997` light/dark report).
Herdr sends `?997` only when the host appearance transitions dark↔light, not on
the first `None → Dark` attach, so the restored TUIs never refreshed
themselves.

## What Phase 20 does

- Sets `[theme] name = "terminal"` so Herdr's chrome follows the terminal.
- Changes `[theme.custom] surface_dim` from `"black"` to `"darkgray"`. The
  shipped `"black"` is ANSI 0, which Omarchy maps to the background, so pane
  dividers were invisible (omarchy#15235).
- Installs `~/.local/bin/opencode-refresh-theme`, which sends `SIGUSR2` only to
  `opencode --session ses_…` TUIs that have a `SIGUSR2` handler (`SigCgt` bit
  `0x800`). It never matches the shared `opencode serve --service` process.
- Binds the helper to `prefix+shift+t` in `~/.config/herdr/config.toml`.

Press `prefix+shift+t` after opening Herdr. The helper re-reads the now-correct
palette and the restored panes repaint.

There is deliberately no launcher wrapper and no custom Omarchy theme. An
earlier version shipped a local `catppuccin-mocha` Omarchy theme with official
ANSI slots, but it only corrected ANSI 0/7/15 and did not reach running foot
terminals: `omarchy-theme-set-foot` recolours from `colors.toml`, not the
theme's `foot.ini`. The keybinding fixes the actual grey-session problem
without that machinery.

## Note: `system` is generated, not Catppuccin

OpenCode's `system` theme is not the Catppuccin palette. It derives muted text,
panels, borders, and diff backgrounds as generated greys from the terminal
background, and uses ANSI colours only for accents. Herdr uses the actual theme
palette, so it looks crisper. That difference is expected and is the cost of
following the system theme.

If exact palette matching matters more than following the terminal, pin the
same fixed theme in both tools instead:

```json
// ~/.config/opencode/cli.json
"theme": { "name": "catppuccin" }
```

```toml
# ~/.config/herdr/config.toml
[theme]
name = "catppuccin"
```

Use `tokyonight` / `tokyo-night` instead if Tokyo Night is the preferred look.
The trade-off is that both tools stop following Omarchy theme changes.

## Validate

```bash
# Herdr follows the terminal and the divider workaround is present.
herdr server reload-config
grep -A2 '^\[theme\]' ~/.config/herdr/config.toml
grep -A3 '^\[theme.custom\]' ~/.config/herdr/config.toml

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
