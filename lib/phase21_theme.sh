#!/bin/bash
# Phase 21: Catppuccin Mocha theme (official terminal palette)
#
# Omarchy's bundled `catppuccin` theme is Catppuccin Mocha, but its generated
# terminal palette maps ANSI 0 to the background and ANSI 7 to the foreground.
# Upstream Catppuccin Mocha defines ANSI 0 as surface0 (#45475a) and ANSI 7 as
# subtext1 (#bac2de), so apps that use the 16-colour palette (including
# OpenCode's `system` theme) looked wrong. See omarchy#12520.
#
# The theme is deployed as a plain directory, not a git checkout, so Omarchy
# keeps the hand-written terminal configs. Themes cloned into
# ~/.config/omarchy/themes with a .git are stripped of ghostty.conf,
# alacritty.toml, foot.ini and kitty.conf. Only Catppuccin Mocha is deployed.

THEME_NAME="catppuccin-mocha"
THEME_SRC="$SCRIPT_DIR/templates/theme/$THEME_NAME"
THEME_DEST="$HOME/.config/omarchy/themes/$THEME_NAME"
THEME_VERSION="1"
THEME_VERSION_FILE="$THEME_DEST/.z13-setup-version"

STOCK_THEME_DIR="/usr/share/omarchy/themes/catppuccin"

phase21_check() {
    [[ -d "$THEME_SRC" ]] || return 1
    [[ -d "$THEME_DEST" ]] || return 1
    [[ -f "$THEME_DEST/ghostty.conf" ]] || return 1
    grep -q 'palette = 0=#45475a' "$THEME_DEST/ghostty.conf" || return 1
    [[ "$(cat "$THEME_VERSION_FILE" 2>/dev/null)" == "$THEME_VERSION" ]] || return 1
    [[ "$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)" == "$THEME_NAME" ]]
}

phase21_run() {
    if ! has_command omarchy; then
        warn "The omarchy command is not available — skipping theme setup."
        return 0
    fi
    if [[ ! -d "$THEME_SRC" ]]; then
        warn "Theme template missing at $THEME_SRC — skipping."
        return 0
    fi

    # A pre-existing directory without our version marker may be a hand-made
    # theme. Keep it rather than silently replacing the user's work.
    if [[ -d "$THEME_DEST" && ! -f "$THEME_VERSION_FILE" ]]; then
        local backup
        backup="$THEME_DEST.bak.$(date +%Y%m%d-%H%M%S)"
        warn "Existing $THEME_NAME theme was not created by this phase; moving it to $backup"
        run_cmd mv "$THEME_DEST" "$backup"
    fi

    run_cmd mkdir -p "$HOME/.config/omarchy/themes"
    run_cmd mkdir -p "$THEME_DEST"

    # Prefer rsync so a template update removes files from an old version.
    if has_command rsync; then
        run_cmd rsync -a --delete "$THEME_SRC/" "$THEME_DEST/"
    else
        run_cmd cp -R "$THEME_SRC/." "$THEME_DEST/"
    fi

    # The stock Catppuccin theme carries the wallpapers and menu previews. Copy
    # them at deploy time instead of vendoring binaries into this repository.
    if [[ -d "$STOCK_THEME_DIR" ]]; then
        if [[ -d "$STOCK_THEME_DIR/backgrounds" ]]; then
            run_cmd mkdir -p "$THEME_DEST/backgrounds"
            run_cmd cp -R "$STOCK_THEME_DIR/backgrounds/." "$THEME_DEST/backgrounds/"
        fi
        local preview
        for preview in preview.png preview-unlock.png unlock.png; do
            if [[ -f "$STOCK_THEME_DIR/$preview" ]]; then
                run_cmd cp "$STOCK_THEME_DIR/$preview" "$THEME_DEST/$preview"
            fi
        done
    else
        warn "Stock Catppuccin theme not found at $STOCK_THEME_DIR; wallpapers/previews were not copied."
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would write theme version $THEME_VERSION to $THEME_VERSION_FILE"
    else
        printf '%s\n' "$THEME_VERSION" > "$THEME_VERSION_FILE"
    fi

    info "Applying Catppuccin Mocha..."
    if ! run_cmd omarchy theme set "$THEME_NAME"; then
        warn "Failed to apply $THEME_NAME — run 'omarchy theme set $THEME_NAME' manually."
        return 0
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        if [[ "$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)" != "$THEME_NAME" ]]; then
            warn "Theme did not become current; expected '$THEME_NAME'."
        fi
        if ! grep -q 'palette = 0=#45475a' "$HOME/.local/state/omarchy/current/theme/ghostty.conf" 2>/dev/null; then
            warn "Current theme does not carry the official Catppuccin ANSI palette."
            warn "Check that $THEME_DEST/ghostty.conf exists and was not stripped."
        fi
    fi

    # Herdr 0.9.1 supplies the host palette to its panes from the client that
    # is attached. A SIGWINCH makes the client re-read the terminal colours, so
    # the panes see Catppuccin before OpenCode is asked to re-detect.
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would signal attached Herdr clients to re-read the terminal palette"
    elif declare -F herdr_client_pids >/dev/null && herdr_client_attached; then
        info "Signalling Herdr to re-read the new terminal palette..."
        while IFS= read -r pid; do
            [[ -n $pid ]] || continue
            kill -WINCH "$pid" 2>/dev/null || true
        done < <(herdr_client_pids)
        sleep 2
    fi

    # OpenCode's system theme caches its generated palette at TUI startup. If the
    # Herdr phase installed the refresh helper, run it now so the currently
    # running TUIs pick up the new colours.
    if [[ -x "$HOME/.local/bin/opencode-refresh-theme" ]]; then
        info "Refreshing running OpenCode themes..."
        run_cmd "$HOME/.local/bin/opencode-refresh-theme" || true
    else
        info "OpenCode refresh helper not installed (Phase 20); restored TUIs will need a restart."
    fi

    info "If Herdr's own chrome still shows the old palette, detach/reattach once."
    success "Catppuccin Mocha theme installed."
}
