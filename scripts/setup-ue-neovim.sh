#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ue-neovim.sh — Neovim + Unreal Engine integration setup
# =============================================================================
# Configures LazyVim with mbwilding/UnrealEngine.nvim for UE C++ development.
# Includes HiDPI scaling fix, project-based nvim tagging, and bidirectional
# file opening between UE Editor and your running nvim instance.
# =============================================================================
# Usage:
#   ./scripts/setup-ue-neovim.sh
#   ./scripts/setup-ue-neovim.sh --help
# =============================================================================

# ── Colors (self-contained) ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ── Usage ──
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Configure Neovim for Unreal Engine C++ development on LazyVim.

Options:
  -h, --help    Show this help message

This script configures:
  - UnrealEngine.nvim plugin (mbwilding/UnrealEngine.nvim)
  - HiDPI scaling fix (SDL_VIDEODRIVER=x11, LD_PRELOAD fake_dpi.so)
  - Project-based nvim tagging (multiple projects supported)
  - :UnrealEngine user commands (open, build, rebuild, lsp, clean)
  - Bidirectional UE <-> nvim file opening

Workflow:
  1. cd /path/to/project && nvim .       # Start nvim in project dir
  2. <leader>uo  or  :UnrealEngine open  # Launch UE from nvim
  3. Double-click C++ class in UE        # Opens in your running nvim
  4. <leader>ub  or  :UnrealEngine build   # Build from nvim

For manual UE launch (e.g., via rofi):
  ue-5.5.4 ProjectName.uproject
  This auto-detects or spawns a tagged nvim instance.

Examples:
  $(basename "$0")
EOF
}

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ── Check Neovim ──
if ! command -v nvim &>/dev/null; then
    error "Neovim not found. Install it first: sudo pacman -S neovim"
    exit 1
fi

NVIM_CONFIG="${HOME}/.config/nvim"
if [[ ! -d "$NVIM_CONFIG" ]]; then
    error "Neovim config not found at ${NVIM_CONFIG}"
    exit 1
fi

info "Neovim found: $(command -v nvim)"

# ── Check LazyVim ──
if [[ ! -f "${NVIM_CONFIG}/init.lua" ]] || ! grep -q "lazy.nvim" "${NVIM_CONFIG}/init.lua" 2>/dev/null; then
    error "LazyVim not detected. This script only supports LazyVim setups."
    exit 1
fi

info "LazyVim detected."

# ── Check engine path ──
ENGINE_PATH="${HOME}/UnrealEngine/5.5.4"
if [[ ! -d "$ENGINE_PATH" ]]; then
    warn "Engine not found at ${ENGINE_PATH}"
    warn "Please adjust engine_path in the generated config if needed."
fi

# ── Backup function ──
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$file" "$backup"
        info "Backed up: ${backup}"
    fi
}

# ── Remove legacy config/ue.lua if it exists ──
LEGACY_CONFIG="${NVIM_CONFIG}/lua/config/ue.lua"
if [[ -f "$LEGACY_CONFIG" ]]; then
    warn "Removing legacy config: ${LEGACY_CONFIG}"
    rm -f "$LEGACY_CONFIG"
fi

# ── Create plugins/ue.lua ──
UE_PLUGIN="${NVIM_CONFIG}/lua/plugins/ue.lua"
info "Installing UE plugin spec..."
backup_file "$UE_PLUGIN"

mkdir -p "$(dirname "$UE_PLUGIN")"
cat > "$UE_PLUGIN" << 'LUAEOF'
-- ~/.config/nvim/lua/plugins/ue.lua
-- Unreal Engine Neovim integration using official mbwilding/UnrealEngine.nvim
-- Enhanced with HiDPI scaling fix, project-based nvim tagging, and :UnrealEngine commands

return {
  {
    "mbwilding/UnrealEngine.nvim",
    lazy = false,
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    keys = {
      { "<leader>ug", function() require("unrealengine.commands").generate_lsp() end, desc = "UnrealEngine: Generate LSP" },
      { "<leader>ub", function() require("unrealengine.commands").build() end,         desc = "UnrealEngine: Build" },
      { "<leader>ur", function() require("unrealengine.commands").rebuild() end,       desc = "UnrealEngine: Rebuild" },
      { "<leader>uo", function() require("unrealengine.commands").open() end,         desc = "UnrealEngine: Open Editor" },
      { "<leader>uc", function() require("unrealengine.commands").clean() end,       desc = "UnrealEngine: Clean" },
      { "<leader>up", function() require("unrealengine.commands").build_plugin() end, desc = "UnrealEngine: Build Plugin" },
    },
    opts = {
      auto_generate = true,
      auto_build = false,
      engine_path = vim.fn.expand("~/UnrealEngine/5.5.4"),
      build_type = "Development",
      with_editor = true,
      register_icon = true,
      register_filetypes = true,
      close_on_success = true,
    },
    config = function(_, opts)
      -- Set environment variables BEFORE setup() so vim.fn.jobstart() inherits them.
      -- These are passed to UE when launched from nvim via :UnrealEngine open.
      --   SDL_VIDEODRIVER=x11:    Force X11 on Wayland (fixes SDL3 UI issues)
      --   LD_PRELOAD=fake_dpi.so: Force 144 DPI scaling (fixes HiDPI)
      --   NVIM:                   Current nvim server address for bidirectional comms
      vim.env.SDL_VIDEODRIVER = "x11"
      vim.env.GDK_SCALE = "1"
      vim.env.QT_SCALE_FACTOR = "1"
      local fake_dpi = vim.fn.expand("~/UnrealEngine/bin/fake_dpi.so")
      if vim.fn.filereadable(fake_dpi) == 1 then
        vim.env.LD_PRELOAD = fake_dpi .. (vim.env.LD_PRELOAD and (":" .. vim.env.LD_PRELOAD) or "")
      end
      -- NVIM server address: UE plugin uses this to send files back via --remote.
      -- Use nvim's actual server address. The wrapper script
      -- (~/UnrealEngine/bin/wrappers/nvim) handles dead socket detection
      -- and auto-spawns new instances when needed.
      vim.env.NVIM = vim.v.servername

      -- Ensure UE uses our nvim wrapper (which prevents freezes on dead sockets)
      -- by prepending it to PATH in the environment passed to UE's jobstart().
      local wrapper_dir = vim.fn.expand("~/UnrealEngine/bin/wrappers")
      if vim.fn.isdirectory(wrapper_dir) == 1 then
        vim.env.PATH = wrapper_dir .. ":" .. vim.env.PATH
      end

      -- Detect UE project at startup from current working directory.
      -- This ensures .projectdir is written and NVIM_UE_PROJECT is set
      -- even when the user runs `nvim .` without opening a specific file first.
      local function detect_project_at_startup()
        if vim.env.NVIM_UE_PROJECT and vim.env.NVIM_UE_PROJECT ~= "" then
          return
        end
        local dir = vim.loop.cwd()
        while dir and dir ~= "/" do
          local files = vim.fn.glob(dir .. "/*.uproject", false, true)
          if #files > 0 then
            local project_name = vim.fn.fnamemodify(files[1], ":t:r")
            vim.env.NVIM_UE_PROJECT = project_name
            local projectdir_file = "/tmp/ue-nvim-" .. project_name .. ".projectdir"
            vim.fn.writefile({dir}, projectdir_file)
            -- NVIM stays as v:servername (random but valid); the wrapper handles respawn
            vim.notify("Tagged nvim for UE project: " .. project_name, vim.log.levels.INFO)
            return
          end
          dir = vim.fn.fnamemodify(dir, ":h")
        end
      end
      detect_project_at_startup()

      require("unrealengine").setup(opts)

      -- Also detect UE project when files are opened (e.g. opening from outside cwd)
      vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
        pattern = { "*.uproject", "*.cpp", "*.h", "*.hpp" },
        callback = function(args)
          if vim.env.NVIM_UE_PROJECT and vim.env.NVIM_UE_PROJECT ~= "" then
            return
          end
          local path = args.match or vim.api.nvim_buf_get_name(args.buf)
          local dir = vim.fn.fnamemodify(path, ":h")
          while dir ~= "/" do
            local files = vim.fn.glob(dir .. "/*.uproject", false, true)
            if #files > 0 then
              local project_name = vim.fn.fnamemodify(files[1], ":t:r")
              vim.env.NVIM_UE_PROJECT = project_name

              -- Write .projectdir so the wrapper can find the project directory
              local projectdir_file = "/tmp/ue-nvim-" .. project_name .. ".projectdir"
              vim.fn.writefile({dir}, projectdir_file)

              vim.notify("Tagged nvim for UE project: " .. project_name, vim.log.levels.INFO)
              return
            end
            dir = vim.fn.fnamemodify(dir, ":h")
          end
        end,
      })

      -- Clean up predictable socket symlink on exit so the launcher/wrapper
      -- know nvim is gone and can respawn a new one.
      vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
          local socket = vim.v.servername
          if socket and socket ~= "" then
            vim.fn.delete(socket)
          end
        end,
      })

      -- Register :UnrealEngine user commands
      vim.api.nvim_create_user_command("UnrealEngine", function(cmd_args)
        local commands = require("unrealengine.commands")
        local cmd = cmd_args.args
        if cmd == "open" or cmd == ""       then commands.open()
        elseif cmd == "build"               then commands.build()
        elseif cmd == "rebuild"             then commands.rebuild()
        elseif cmd == "lsp" or cmd == "generate_lsp" then commands.generate_lsp()
        elseif cmd == "clean"               then commands.clean()
        elseif cmd == "plugin" or cmd == "build_plugin" then commands.build_plugin()
        elseif cmd == "engine" or cmd == "build_engine" then commands.build_engine()
        else vim.notify("Unknown UnrealEngine command: " .. cmd, vim.log.levels.ERROR)
        end
      end, {
        nargs = "?",
        complete = function() return { "open", "build", "rebuild", "lsp", "clean", "plugin", "engine" } end,
        desc = "UnrealEngine: open|build|rebuild|lsp|clean|plugin|engine",
      })
    end,
  },
}
LUAEOF

success "Created: ${UE_PLUGIN}"

# ── Check launcher script ──
LAUNCHER="${HOME}/UnrealEngine/bin/ue-5.5.4"
if [[ -f "$LAUNCHER" ]]; then
    if grep -q "NVIM_UE_PROJECT" "$LAUNCHER"; then
        success "Launcher already has project-based nvim detection."
    else
        warn "Launcher ${LAUNCHER} does not have nvim auto-detection."
        warn "Consider updating it or use 'ue-5.5.4 <project>.uproject' for auto-spawn."
    fi
else
    warn "Launcher not found at ${LAUNCHER}"
fi

# ── Enable NeovimSourceCodeAccess plugin globally ──
enable_plugin_globally() {
    local engine_path="${HOME}/UnrealEngine/5.5.4"
    local uplugin="${engine_path}/Engine/Plugins/Developer/NeovimSourceCodeAccess/NeovimSourceCodeAccess.uplugin"

    if [[ ! -f "$uplugin" ]]; then
        warn "NeovimSourceCodeAccess plugin not found at ${uplugin}"
        warn "This is expected if you haven't built the plugin from mbwilding/UnrealEngine.nvim yet."
        warn "Build steps:"
        warn "  1. cd ~/.local/share/nvim/lazy/UnrealEngine.nvim  (or where you cloned it)"
        warn "  2. Follow the build instructions in the repo (typically RunUAT)"
        warn "  3. Copy the built plugin to ${engine_path}/Engine/Plugins/Developer/"
        warn "  4. Re-run this script: ./scripts/setup-ue-neovim.sh"
        return 0
    fi

    # Check if EnabledByDefault is already set
    if grep -q '"EnabledByDefault"' "$uplugin"; then
        if grep -q '"EnabledByDefault": true' "$uplugin"; then
            success "NeovimSourceCodeAccess already enabled by default globally."
            return 0
        fi
        # Exists but false — flip to true
        info "Updating EnabledByDefault to true..."
        sed -i 's/"EnabledByDefault": false/"EnabledByDefault": true/' "$uplugin" || {
            warn "Failed to patch .uplugin with sed."
            return 0
        }
    else
        # Add EnabledByDefault: true to the JSON
        info "Adding EnabledByDefault: true to plugin descriptor..."
        if command -v python3 &>/dev/null; then
            python3 -c "
import json
with open('$uplugin', 'r') as f:
    data = json.load(f)
data['EnabledByDefault'] = True
with open('$uplugin', 'w') as f:
    json.dump(data, f, indent=4)
" || {
                warn "Failed to patch .uplugin with python3."
                return 0
            }
        else
            warn "python3 not found — cannot patch .uplugin. Install python and re-run."
            return 0
        fi
    fi

    success "NeovimSourceCodeAccess enabled by default for all UE projects on this machine."
    info "No need to add it to .uproject files anymore."
}

enable_plugin_globally || true

# ── Set Neovim as default source code editor in UE ──
set_default_source_editor() {
    local engine_path="${HOME}/UnrealEngine/5.5.4"
    local base_editor_ini="${engine_path}/Engine/Config/BaseEditor.ini"

    if [[ ! -f "$base_editor_ini" ]]; then
        warn "BaseEditor.ini not found at ${base_editor_ini}"
        warn "Unreal Engine may not be installed yet."
        return 0
    fi

    # Check if section already exists
    if grep -q '\[\/?Script\/SourceCodeAccess\.SourceCodeAccessSettings\]' "$base_editor_ini"; then
        if grep -A1 '\[\/?Script\/SourceCodeAccess\.SourceCodeAccessSettings\]' "$base_editor_ini" | grep -q 'PreferredAccessor=NeovimSourceCodeAccess'; then
            success "Neovim already set as default source code editor in BaseEditor.ini."
            return 0
        fi
        # Section exists but points to something else — update it
        info "Updating PreferredAccessor to NeovimSourceCodeAccess in BaseEditor.ini..."
        sed -i '/PreferredAccessor=/c\PreferredAccessor=NeovimSourceCodeAccess' "$base_editor_ini" || {
            warn "Failed to patch BaseEditor.ini with sed."
            return 0
        }
    else
        # Append new section
        info "Adding SourceCodeAccessSettings section to BaseEditor.ini..."
        echo "" >> "$base_editor_ini"
        echo "[/Script/SourceCodeAccess.SourceCodeAccessSettings]" >> "$base_editor_ini"
        echo "PreferredAccessor=NeovimSourceCodeAccess" >> "$base_editor_ini"
    fi

    success "Neovim set as default source code editor for all UE projects on this machine."
    info "No need to change Edit → Editor Preferences → Source Code manually anymore."
}

set_default_source_editor || true

# ── Summary ──
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Neovim UE Setup Complete                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
success "LazyVim configured for Unreal Engine development."
echo ""
info "What was installed:"
echo "  ${UE_PLUGIN}  - UnrealEngine.nvim plugin + :UnrealEngine commands"
echo ""
info "Workflow:"
echo "  1. cd /path/to/UE/project && nvim .    # Start nvim (auto-tags project)"
echo "  2. <leader>uo  or  :UnrealEngine open  # Launch UE from nvim"
echo "  3. Double-click C++ class in UE        # Opens in your running nvim"
echo "  4. <leader>ub  or  :UnrealEngine build   # Build from nvim"
echo ""
info "Manual UE launch (also works):"
echo "  ue-5.5.4 ProjectName.uproject"
echo "  → Auto-detects tagged nvim or spawns a new one"
echo ""
info "Generate LSP cache (run once per project):"
echo "  :UnrealEngine lsp"
echo "  → Creates compile_commands.json and .clangd"
echo ""
info "Global plugin enable:"
echo "  This script patched NeovimSourceCodeAccess.uplugin with EnabledByDefault: true"
echo "  → No need to add the plugin to your .uproject files anymore"
echo ""
info "Default source code editor:"
echo "  This script patched BaseEditor.ini with PreferredAccessor=NeovimSourceCodeAccess"
echo "  → Neovim is already selected as the default editor, no manual preference change needed"
echo ""
info "If the plugin was NOT found during this run:"
echo "  Build it from mbwilding/UnrealEngine.nvim first, then re-run this script:"
echo "    ./scripts/setup-ue-neovim.sh"
echo "  (Both patches above will be applied on re-run once the plugin exists.)"
echo ""
info "Troubleshooting:"
echo "  - Files not opening in nvim: Launch UE FROM nvim, not manually"
echo "  - LSP not working: Run :UnrealEngine lsp"
echo "  - Multiple projects: Each project gets its own tagged nvim instance"
echo ""
info "For help, visit: https://github.com/mbwilding/UnrealEngine.nvim"
echo ""
