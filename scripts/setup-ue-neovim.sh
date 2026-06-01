#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ue-neovim.sh — Neovim configuration for Unreal Engine C++ development
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

This script auto-detects your LazyVim setup and installs:
  - UnrealEngine.nvim plugin (mbwilding/UnrealEngine.nvim)
  - Auto-detection logic (reads .uproject → finds engine → sets clangd)

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

# ── Backup function ──
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$file" "$backup"
        info "Backed up: ${backup}"
    fi
}

# ── Create config/ue.lua ──
UE_CONFIG="${NVIM_CONFIG}/lua/config/ue.lua"
info "Installing UE auto-detection config..."
backup_file "$UE_CONFIG"

mkdir -p "$(dirname "$UE_CONFIG")"
cat > "$UE_CONFIG" << 'EOF'
-- ~/.config/nvim/lua/config/ue.lua
-- Unreal Engine auto-detection for Neovim
-- Reads .uproject files to find engine version and configure LSP

local M = {}

--- Find .uproject file in current file's parent directories
function M.find_uproject()
  local path = vim.fn.expand("%:p")
  local dir = vim.fn.fnamemodify(path, ":h")

  while dir ~= "/" do
    local uproject = vim.fn.glob(dir .. "/*.uproject", false, true)
    if #uproject > 0 then
      return uproject[1], dir
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  return nil, nil
end

--- Parse EngineAssociation from .uproject JSON
function M.get_engine_version(uproject_path)
  if not uproject_path then
    return nil
  end

  local content = vim.fn.readfile(uproject_path)
  if not content or #content == 0 then
    return nil
  end

  local json_str = table.concat(content, "\n")
  local version = json_str:match('"EngineAssociation"%s*:%s*"([0-9.]+)"')

  return version
end

--- Map engine version to install directory
function M.get_engine_dir(version)
  if not version then
    return nil
  end

  -- Try exact version first (e.g., 5.5.4)
  local exact = vim.fn.expand("~/UnrealEngine/" .. version)
  if vim.fn.isdirectory(exact) == 1 then
    return exact
  end

  -- Try major.minor (e.g., 5.5 -> 5.5.4)
  local major_minor = version:match("^([0-9]+\.[0-9]+)")
  if major_minor then
    local pattern = vim.fn.expand("~/UnrealEngine/" .. major_minor .. "*")
    local matches = vim.fn.glob(pattern, false, true)
    if #matches > 0 then
      return matches[1]
    end
  end

  return nil
end

--- Get compile_commands.json directory for detected project
function M.get_compile_commands_dir()
  local uproject, project_dir = M.find_uproject()
  if not uproject then
    return nil
  end

  local version = M.get_engine_version(uproject)
  local engine_dir = M.get_engine_dir(version)

  if not engine_dir then
    vim.notify(
      "UE: Could not find engine for version " .. (version or "unknown"),
      vim.log.levels.WARN
    )
    return nil
  end

  -- compile_commands.json is generated in the engine dir
  local compile_db = engine_dir .. "/compile_commands.json"

  if vim.fn.filereadable(compile_db) == 0 then
    vim.notify(
      "UE: compile_commands.json not found.\n"
        .. "Generate it with:\n"
        .. "  cd " .. project_dir .. "\n"
        .. "  make YourProjectEditor ARGS=\"-Mode=GenerateClangDatabase\"",
      vim.log.levels.WARN
    )
    return nil
  end

  return engine_dir
end

return M
EOF

success "Created: ${UE_CONFIG}"

# ── Create plugins/ue.lua ──
UE_PLUGIN="${NVIM_CONFIG}/lua/plugins/ue.lua"
info "Installing UE plugin spec..."
backup_file "$UE_PLUGIN"

mkdir -p "$(dirname "$UE_PLUGIN")"
cat > "$UE_PLUGIN" << 'EOF'
-- ~/.config/nvim/lua/plugins/ue.lua
-- Unreal Engine Neovim integration for LazyVim
-- Auto-detects UE projects and configures LSP

return {
  {
    "mbwilding/UnrealEngine.nvim",
    dependencies = {
      "neovim/nvim-lspconfig",
    },
    ft = { "cpp", "h", "hpp" },
    config = function()
      local ok, ue = pcall(require, "config.ue")
      if not ok then
        vim.notify("UE: config.ue.lua not found", vim.log.levels.WARN)
        return
      end

      local uproject = ue.find_uproject()
      local version = ue.get_engine_version(uproject)
      local engine_dir = ue.get_engine_dir(version)

      require("UnrealEngine").setup({
        engine_dir = engine_dir,
      })
    end,
  },

  -- Override clangd config for UE projects
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        clangd = {
          -- Auto-detect compile_commands.json for UE projects
          on_new_config = function(new_config, _)
            local ok, ue = pcall(require, "config.ue")
            if not ok then
              return
            end

            local compile_dir = ue.get_compile_commands_dir()
            if compile_dir then
              -- Insert compile-commands-dir into cmd args
              table.insert(new_config.cmd, 2, "--compile-commands-dir=" .. compile_dir)
            end
          end,
        },
      },
    },
  },
}
EOF

success "Created: ${UE_PLUGIN}"

# ── Summary ──
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Neovim UE Setup Complete                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
success "LazyVim configured for Unreal Engine development."
echo ""
info "What was installed:"
echo "  ${UE_CONFIG}     - Auto-detect engine from .uproject files"
echo "  ${UE_PLUGIN}  - UnrealEngine.nvim plugin + clangd integration"
echo ""
info "Next steps:"
echo "  1. Open Neovim and run :Lazy to install UnrealEngine.nvim"
echo "  2. Open any C++ file in your UE project"
echo "  3. The plugin will auto-detect the engine and configure LSP"
echo ""
info "Generate compile_commands.json for your project:"
echo "  cd /path/to/project"
echo "  make ProjectNameEditor ARGS=\"-Mode=GenerateClangDatabase\""
echo ""
info "For help, visit: https://github.com/mbwilding/UnrealEngine.nvim"
echo ""
