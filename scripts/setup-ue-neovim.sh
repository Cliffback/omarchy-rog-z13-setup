#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ue-neovim.sh — Optional Neovim configuration for Unreal Engine dev
# =============================================================================
# Usage:
#   ./scripts/setup-ue-neovim.sh --engine-dir ~/UnrealEngine/5.5.4
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

Configure Neovim for Unreal Engine C++ development.

Options:
  -e, --engine-dir <path>  Path to Unreal Engine install (e.g., ~/UnrealEngine/5.5.4)
  -h, --help               Show this help message

Examples:
  $(basename "$0") --engine-dir ~/UnrealEngine/5.5.4
EOF
}

# ── Parse args ──
ENGINE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--engine-dir)
            ENGINE_DIR="${2:-}"
            [[ -z "$ENGINE_DIR" ]] && { error "--engine-dir requires an argument."; usage; exit 1; }
            shift 2
            ;;
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

# ── Detect Neovim ──
if ! command -v nvim &>/dev/null; then
    error "Neovim not found. Install it first: sudo pacman -S neovim"
    exit 1
fi

info "Neovim found: $(command -v nvim)"

# ── Resolve engine dir ──
if [[ -z "$ENGINE_DIR" ]]; then
    # Try to auto-detect
    if [[ -d "${HOME}/UnrealEngine" ]]; then
        local detected
        detected=$(find "${HOME}/UnrealEngine" -maxdepth 1 -mindepth 1 -type d | head -n 1)
        if [[ -n "$detected" ]]; then
            read -rp "Use detected engine dir: ${detected}? [Y/n] " answer
            if [[ ! "$answer" =~ ^[Nn]$ ]]; then
                ENGINE_DIR="$detected"
            fi
        fi
    fi
fi

if [[ -z "$ENGINE_DIR" ]]; then
    read -rp "Path to Unreal Engine install (e.g., ~/UnrealEngine/5.5.4): " ENGINE_DIR
fi

ENGINE_DIR="$(realpath -m "${ENGINE_DIR/#\~/$HOME}")"

if [[ ! -d "$ENGINE_DIR" ]]; then
    error "Engine directory not found: ${ENGINE_DIR}"
    exit 1
fi

if [[ ! -f "${ENGINE_DIR}/Engine/Binaries/Linux/UnrealEditor" ]]; then
    warn "UnrealEditor binary not found in ${ENGINE_DIR}"
    read -rp "Continue anyway? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

info "Using engine directory: ${ENGINE_DIR}"

# ── Detect plugin manager ──
NVIM_CONFIG="${HOME}/.config/nvim"
PLUGIN_MANAGER=""

if [[ -f "${NVIM_CONFIG}/init.lua" ]]; then
    if grep -q "lazy.nvim" "${NVIM_CONFIG}/init.lua" 2>/dev/null; then
        PLUGIN_MANAGER="lazy"
    elif grep -q "packer" "${NVIM_CONFIG}/init.lua" 2>/dev/null; then
        PLUGIN_MANAGER="packer"
    elif grep -q "vim-plug" "${NVIM_CONFIG}/init.lua" 2>/dev/null; then
        PLUGIN_MANAGER="plug"
    fi
elif [[ -f "${NVIM_CONFIG}/init.vim" ]]; then
    if grep -q "vim-plug" "${NVIM_CONFIG}/init.vim" 2>/dev/null; then
        PLUGIN_MANAGER="plug"
    fi
fi

if [[ -z "$PLUGIN_MANAGER" ]]; then
    warn "Could not detect Neovim plugin manager."
    info "Supported: lazy.nvim, packer.nvim, vim-plug"
    echo ""
    info "Manual setup instructions:"
    echo "  1. Install one of the supported plugin managers"
    echo "  2. Add a UE plugin (see recommendations below)"
    echo "  3. Configure clangd with compile_commands.json from your project"
    echo ""
fi

# ── Recommend plugins ──
echo ""
echo "Recommended Unreal Engine Neovim plugins:"
echo ""
echo "  mbwilding/UnrealEngine.nvim  (full integration, 57⭐)"
echo "    - Project parsing, LSP, build integration"
echo "    - https://github.com/mbwilding/UnrealEngine.nvim"
echo ""
echo "  taku25/UnrealDev.nvim        (meta-suite, 40⭐)"
echo "    - Combines UEP + UBT + UCM + ULG plugins"
echo "    - https://github.com/taku25/UnrealDev.nvim"
echo ""
echo "  Individual plugins (taku25):"
echo "    - UEP.nvim  : .uproject file parsing and navigation"
echo "    - UBT.nvim  : UnrealBuildTool integration"
echo "    - UCM.nvim  : C++ class generation (.h/.cpp pairs)"
echo "    - ULG.nvim  : Real-time UE log viewer"
echo ""

# ── clangd setup ──
echo ""
info "clangd configuration for Unreal Engine..."

# Find bundled clang
CLANG_DIR=""
for dir in "${ENGINE_DIR}/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/*/x86_64-unknown-linux-gnu/bin" \
           "${ENGINE_DIR}/Engine/Build/BatchFiles/Linux" \
           "${ENGINE_DIR}/Engine/Extras/ThirdPartyNotUE/Clang" ; do
    if [[ -d "$dir" ]]; then
        CLANG_DIR="$dir"
        break
    fi
done

if [[ -n "$CLANG_DIR" ]]; then
    info "Found bundled toolchain: ${CLANG_DIR}"
else
    warn "Could not find bundled clang toolchain."
    info "You may need to generate compile_commands.json from your project."
fi

echo ""
echo "For C++ LSP to work with UE, you need a compile_commands.json."
echo "Generate it from your project:"
echo ""
echo "  1. Open your .uproject in Unreal Editor"
echo "  2. Tools > Refresh Visual Studio Code Project"
echo "     (this generates compile_commands.json)"
echo ""
echo "  OR run from your project root:"
echo "    ${ENGINE_DIR}/Engine/Build/BatchFiles/Linux/Build.sh \\"
echo "      YourProject Linux Development -Mode=GenerateClangDatabase"
echo ""

# ── Optional: create a project helper script ──
UE_HELPER="${HOME}/.local/bin/ue-project-init"
if [[ ! -f "$UE_HELPER" ]]; then
    read -rp "Create ue-project-init helper script? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "$UE_HELPER")"
        cat > "$UE_HELPER" << EOF
#!/bin/bash
# Helper to initialize a new Unreal Engine project for Neovim/LSP

set -euo pipefail

PROJECT_NAME="\${1:-}"
if [[ -z "\$PROJECT_NAME" ]]; then
    echo "Usage: ue-project-init <ProjectName>"
    exit 1
fi

ENGINE_DIR="${ENGINE_DIR}"
PROJECT_DIR="\$(pwd)/\$PROJECT_NAME"

echo "Creating UE project: \$PROJECT_NAME"
echo "Engine: \$ENGINE_DIR"
echo "Project dir: \$PROJECT_DIR"

# Create project via UnrealEditor commandlet
# Note: this requires the editor to run headlessly, which may not work on all setups
# Alternative: create in editor, then run GenerateProjectFiles

# After project creation, generate compile_commands.json:
# \$ENGINE_DIR/Engine/Build/BatchFiles/Linux/Build.sh \\
#   \$PROJECT_NAME Linux Development -Mode=GenerateClangDatabase
EOF
        chmod +x "$UE_HELPER"
        success "Created: ${UE_HELPER}"
    fi
fi

# ── Summary ──
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Neovim UE Setup Instructions             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
success "Engine directory configured: ${ENGINE_DIR}"
echo ""
info "Next steps:"
echo "  1. Install a UE Neovim plugin (see recommendations above)"
if [[ -n "$PLUGIN_MANAGER" ]]; then
    echo "     Detected plugin manager: ${PLUGIN_MANAGER}"
fi
echo "  2. Open a UE project in the editor"
echo "  3. Generate compile_commands.json (Tools > Refresh VS Code Project)"
echo "  4. Open the project in Neovim and enjoy LSP + UE integration"
echo ""
info "For help, visit: https://github.com/mbwilding/UnrealEngine.nvim"
echo ""
