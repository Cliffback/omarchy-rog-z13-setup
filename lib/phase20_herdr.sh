#!/bin/bash
# Phase 20: Herdr terminal integration
#
# Omarchy starts `herdr server` at login, before any Herdr client can supply the
# terminal palette. Herdr then resumes OpenCode panes with its fallback palette,
# and OpenCode's `system` theme caches that generated palette. A theme switch
# does not fix it either: omarchy-restart-opencode matches a process named
# `opencode`, while mise installs OpenCode 2 as `opencode.exe` (omarchy#17374,
# fixed by #17438).
#
# This phase makes Herdr follow the terminal palette (`theme = "terminal"`) and
# installs a small SIGUSR2 refresh so restored OpenCode TUIs re-read the palette
# after the client attaches. The `prefix+shift+t` binding runs that refresh; it
# is deliberately manual rather than shadowing Omarchy's terminal launcher.
#
# OpenCode stays on `theme = "system"`, so it follows the same terminal palette
# as Herdr. Its generated grays are flatter than a fixed theme by design; pin a
# fixed theme in both tools if exact palette matching matters more than
# following the system.

HERDR_CONFIG_DIR="$HOME/.config/herdr"
HERDR_CONFIG="$HERDR_CONFIG_DIR/config.toml"
HERDR_STOCK_CONFIG="/usr/share/omarchy/config/herdr/config.toml"

HERDR_REFRESH_SCRIPT="$HOME/.local/bin/opencode-refresh-theme"

HERDR_REFRESH_KEY="prefix+shift+t"

# Return one value from a TOML section. The parser is intentionally small: it
# only needs the scalar keys this phase owns, and it must preserve the rest of
# the user's hand-written config when writing.
toml_section_value() {
    local file="$1" section="$2" key="$3"
    awk -v section="$section" -v key="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        /^[[:space:]]*\[/ {
            header = trim($0)
            sub(/[[:space:]]*#.*$/, "", header)
            in_section = (header == section)
            next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]*#.*$/, "", value)
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$file"
}

# Set (or insert) a scalar key inside a TOML section, preserving every other
# line. If the section is missing it is appended. The config file is small and
# user-written, so a line-oriented edit is safer than re-serialising it.
toml_set_in_section() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would set $section $key = \"$value\" in $file"
        return 0
    fi

    tmp=$(mktemp)
    awk -v section="$section" -v key="$key" -v value="$value" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function emit_missing() {
            if (in_section && !done) {
                print key " = \"" value "\""
                done = 1
            }
        }
        BEGIN { in_section = 0; done = 0; found_section = 0 }
        /^[[:space:]]*\[/ {
            emit_missing()
            header = trim($0)
            sub(/[[:space:]]*#.*$/, "", header)
            in_section = (header == section)
            if (in_section) found_section = 1
            print
            next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            print key " = \"" value "\""
            done = 1
            next
        }
        { print }
        END {
            emit_missing()
            if (!found_section) {
                print ""
                print section
                print key " = \"" value "\""
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Print the PIDs of attached Herdr clients. `pgrep -x herdr` matches both the
# client and `herdr server`; the server's argv contains " server".
herdr_client_pids() {
    local pid cmd
    for pid in $(pgrep -x herdr 2>/dev/null || true); do
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        case "$cmd" in
            *" server"*) continue ;;
        esac
        printf '%s\n' "$pid"
    done
}

# True when a Herdr client is attached.
herdr_client_attached() {
    [[ -n "$(herdr_client_pids)" ]]
}

phase20_check() {
    has_command herdr || return 1
    [[ -f "$HERDR_CONFIG" ]] || return 1
    [[ "$(toml_section_value "$HERDR_CONFIG" '[theme]' name)" == "terminal" ]] || return 1
    [[ "$(toml_section_value "$HERDR_CONFIG" '[theme.custom]' surface_dim)" == "darkgray" ]] || return 1
    [[ -x "$HERDR_REFRESH_SCRIPT" ]] || return 1
    file_contains "$HERDR_CONFIG" "opencode-refresh-theme"
}

phase20_run() {
    if ! is_pkg_installed herdr; then
        if pacman -Si herdr &>/dev/null; then
            info "Installing Herdr..."
            run_sudo pacman -S --needed --noconfirm herdr
            success "Herdr installed."
        else
            warn "Herdr is not installed and not available in the configured repos."
            warn "Install it, then re-run this phase."
            return 0
        fi
    fi

    # Start from Omarchy's shipped config on a fresh machine. An existing user
    # config is never replaced: only the two keys below are edited.
    if [[ ! -f "$HERDR_CONFIG" ]]; then
        run_cmd mkdir -p "$HERDR_CONFIG_DIR"
        if [[ -f "$HERDR_STOCK_CONFIG" ]]; then
            info "Creating Herdr config from Omarchy's default..."
            run_cmd cp "$HERDR_STOCK_CONFIG" "$HERDR_CONFIG"
        else
            info "Creating a minimal Herdr config..."
            if [[ $DRY_RUN -eq 0 ]]; then
                cat > "$HERDR_CONFIG" <<'EOF'
[theme]
name = "terminal"
auto_switch = false

[theme.custom]
panel_bg = "reset"
surface_dim = "darkgray"
EOF
            fi
        fi
    fi

    # `terminal` makes Herdr's chrome follow the outer terminal's ANSI palette.
    # `darkgray` is ANSI 8 (the theme's muted colour): with the stock
    # `surface_dim = "black"` (ANSI 0, which Omarchy maps to the background) the
    # pane dividers are invisible (omarchy#15235).
    toml_set_in_section "$HERDR_CONFIG" '[theme]' 'name' 'terminal'
    toml_set_in_section "$HERDR_CONFIG" '[theme.custom]' 'surface_dim' 'darkgray'

    info "Installing OpenCode theme-refresh helper..."
    run_cmd mkdir -p "$HOME/.local/bin"
    run_cmd cp "$SCRIPT_DIR/templates/herdr/opencode-refresh-theme" "$HERDR_REFRESH_SCRIPT"
    run_cmd chmod +x "$HERDR_REFRESH_SCRIPT"
    success "Installed $HERDR_REFRESH_SCRIPT"

    if file_contains "$HERDR_CONFIG" "opencode-refresh-theme"; then
        info "OpenCode refresh keybinding already present."
    else
        info "Adding prefix+shift+t refresh keybinding..."
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] would append the opencode-refresh-theme keybinding to $HERDR_CONFIG"
        else
            # Keep the array-of-tables at the end of the file and start it on a
            # fresh line if the user's config lost its trailing newline.
            if [[ -s "$HERDR_CONFIG" && -n "$(tail -c 1 "$HERDR_CONFIG")" ]]; then
                printf '\n' >> "$HERDR_CONFIG"
            fi
            cat >> "$HERDR_CONFIG" <<EOF

# Refresh OpenCode's generated system theme after Herdr attaches. Press this
# after opening Herdr so restored panes re-read the host terminal palette.
[[keys.command]]
key = "$HERDR_REFRESH_KEY"
type = "shell"
command = "~/.local/bin/opencode-refresh-theme"
description = "refresh opencode themes"
EOF
        fi
        success "Refresh keybinding added."
    fi

    if has_command herdr && herdr status server --json 2>/dev/null | grep -q '"running"[[:space:]]*:[[:space:]]*true'; then
        info "Reloading Herdr configuration..."
        run_cmd herdr server reload-config || warn "Herdr reported a config problem — run 'herdr server reload-config' to see it."
    else
        info "Herdr server is not running; the config will apply on next launch."
    fi

    if herdr_client_attached; then
        info "Refreshing OpenCode themes in the attached Herdr session..."
        run_cmd "$HERDR_REFRESH_SCRIPT" || true
    else
        info "No Herdr client attached. After opening Herdr, press $HERDR_REFRESH_KEY to refresh restored panes."
    fi

    success "Herdr terminal integration configured."
}
