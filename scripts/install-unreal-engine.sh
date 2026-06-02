#!/bin/bash
set -euo pipefail

# =============================================================================
# install-unreal-engine.sh — Standalone Unreal Engine 5 binary installer
# For Omarchy (Hyprland/Wayland) on ASUS ROG Flow Z13
# =============================================================================
# Usage:
#   ./scripts/install-unreal-engine.sh              # Interactive mode
#   ./scripts/install-unreal-engine.sh --dry-run    # Preview mode
#   ./scripts/install-unreal-engine.sh --help       # Show help
# =============================================================================

# ── Self-contained constants ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates/unreal-engine"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${HOME}/Downloads}"
INSTALL_BASE="${HOME}/UnrealEngine"
BIN_DIR="${INSTALL_BASE}/bin"
DESKTOP_DIR="${HOME}/.local/share/applications"
ICON_BASE="${HOME}/.local/share/icons/hicolor"
MIME_DIR="${HOME}/.local/share/mime/packages"
MIN_FILE_BYTES=$((1024 * 1024 * 1024))  # 1 GB sanity check

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

Install Unreal Engine 5 binary releases on Omarchy Linux.

Scans ${DOWNLOADS_DIR}/ for manually downloaded Linux_Unreal_Engine_*.zip files.
You must download the zip from Epic's website first:
  https://www.unrealengine.com/linux (requires Epic login)

Options:
  -d, --dry-run         Show what would be done without making changes
  -h, --help            Show this help message

Examples:
  $(basename "$0")                          # Interactive install
  $(basename "$0") --dry-run                # Preview mode
EOF
}

# ── Parse args ──
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=1
            shift
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

# ── Dry-run wrapper ──
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    "$@"
}

# ── Scan Downloads for UE zips ──
find_ue_zips() {
    local dir="$1"
    local -n arr="$2"
    local -n vers="$3"

    arr=()
    vers=()

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    local file version
    for file in "${dir}"/Linux_Unreal_Engine_*.zip; do
        [[ -f "$file" ]] || continue
        # Extract version from filename: Linux_Unreal_Engine_5.6.1.zip
        version=$(basename "$file" | sed -n 's/^Linux_Unreal_Engine_\([0-9]\+\.[0-9]\+\.[0-9]\+\)\.zip$/\1/p')
        if [[ -n "$version" ]]; then
            arr+=("$file")
            vers+=("$version")
        fi
    done
}

# ── Check available disk space ──
check_disk_space() {
    local needed_gb="$1"
    local available_kb
    available_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $needed_gb ]]; then
        warn "Low disk space: ${available_gb}GB available, ${needed_gb}GB recommended."
        if [[ $DRY_RUN -eq 0 ]]; then
            read -rp "Continue anyway? [y/N] " answer
            [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
        fi
    else
        info "Disk space OK: ${available_gb}GB available."
    fi
}

# ── Extract release ──
extract_release() {
    local zip_file="$1"
    local version="$2"
    local dest_dir="${INSTALL_BASE}/${version}"

    if [[ -d "$dest_dir" ]]; then
        warn "Target directory already exists: ${dest_dir}"
        if [[ $DRY_RUN -eq 0 ]]; then
            read -rp "Remove existing install? [y/N] " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                rm -rf "$dest_dir"
            else
                info "Aborted."
                exit 0
            fi
        fi
    fi

    info "Extracting to ${dest_dir}..."
    run_cmd mkdir -p "$dest_dir"

    if command -v 7z &>/dev/null; then
        run_cmd 7z x "$zip_file" -o"$dest_dir" -y
    elif command -v unzip &>/dev/null; then
        run_cmd unzip -q "$zip_file" -d "$dest_dir"
    else
        error "Neither 7z nor unzip found. Install one: sudo pacman -S p7zip unzip"
        rm -rf "$dest_dir"
        exit 1
    fi

    # Epic's zip typically wraps everything in a single folder like Linux_Unreal_Engine_5.5.4/
    # If we find a single subdirectory with no siblings, move contents up one level
    local subdirs_count
    subdirs_count=$(find "$dest_dir" -maxdepth 1 -mindepth 1 -type d | wc -l)
    if [[ "$subdirs_count" -eq 1 ]]; then
        local wrapper_dir
        wrapper_dir=$(find "$dest_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)
        if [[ -d "${wrapper_dir}/Engine" ]]; then
            info "Flattening wrapper directory: $(basename "$wrapper_dir")"
            # Move all contents from wrapper to dest_dir root
            local item
            for item in "$wrapper_dir"/*; do
                run_cmd mv "$item" "$dest_dir/"
            done
            run_cmd rmdir "$wrapper_dir"
        fi
    fi

    # Verify Engine/ directory exists
    if [[ ! -d "${dest_dir}/Engine" ]]; then
        error "Engine/ directory not found after extraction."
        error "The zip structure may have changed. Check ${dest_dir}"
        exit 1
    fi

    success "Extracted to ${dest_dir}"
}

# ── Fix permissions ──
fix_permissions() {
    local version="$1"
    local engine_dir="${INSTALL_BASE}/${version}"

    info "Fixing permissions for shader compilation..."
    # UE needs write access to Engine/ for shader cache and intermediate files
    run_cmd chmod -R a+rwX "${engine_dir}/Engine"
    success "Permissions fixed."
}

# ── Add Hyprland window rule for UE dialogs ──
add_hyprland_windowrule() {
    local HYPRLAND_CONF="${HOME}/.config/hypr/hyprland.conf"

    if [[ ! -f "$HYPRLAND_CONF" ]]; then
        info "Hyprland config not found — skipping window rule."
        return 0
    fi

    if grep -q "match:class UnrealEditor" "$HYPRLAND_CONF" 2>/dev/null; then
        info "UE window rule already present in Hyprland config."
        return 0
    fi

    info "Adding Hyprland window rule for UE dialogs..."
    if [[ $DRY_RUN -eq 0 ]]; then
        echo "" >> "$HYPRLAND_CONF"
        echo "# Center Unreal Editor windows (dialogs, settings, etc. spawn off-center on XWayland)" >> "$HYPRLAND_CONF"
        echo "windowrule = center 1, match:class UnrealEditor" >> "$HYPRLAND_CONF"
    fi
    success "Window rule added to ${HYPRLAND_CONF}"
}

# ── Install icons ──
install_icons() {
    local template_dir="$1"

    info "Installing application icons..."

    local size
    for size in 16 24 32 48 64 256; do
        local src="${template_dir}/${size}.png"
        local dst_dir="${ICON_BASE}/${size}x${size}/apps"
        if [[ -f "$src" ]]; then
            run_cmd mkdir -p "$dst_dir"
            run_cmd cp "$src" "${dst_dir}/unreal-engine.png"
        fi
    done

    run_cmd gtk-update-icon-cache -f "$ICON_BASE" 2>/dev/null || true
    success "Icons installed."
}

# ── Install MIME type ──
install_mime() {
    local template_dir="$1"

    info "Installing MIME type for .uproject files..."

    # perl-file-mimeinfo provides the 'mimetype' command which xdg-mime prefers
    # over 'file'. Without it, .uproject files (which are JSON) get sniffed as
    # application/json and open in a text editor instead of UE.
    if ! command -v mimetype &>/dev/null; then
        info "Installing perl-file-mimeinfo (required for correct .uproject MIME detection)..."
        run_cmd sudo pacman -S --needed --noconfirm perl-file-mimeinfo
    fi

    run_cmd mkdir -p "$MIME_DIR"
    run_cmd cp "${template_dir}/unreal-engine.xml" "${MIME_DIR}/application-x-uproject.xml"
    run_cmd update-mime-database "${HOME}/.local/share/mime" 2>/dev/null || true
    success "MIME type installed."
}

# ── Compile fake DPI library ──
compile_fake_dpi() {
    local src_file="${TEMPLATES_DIR}/fake_dpi.c"
    local out_file="${BIN_DIR}/fake_dpi.so"

    if [[ ! -f "$src_file" ]]; then
        warn "fake_dpi.c not found in templates — skipping LD_PRELOAD fix."
        return 1
    fi

    info "Compiling fake DPI library..."

    if ! command -v gcc &>/dev/null; then
        warn "gcc not found. Install it: sudo pacman -S gcc"
        warn "Without gcc, the HiDPI fix won't be available."
        return 1
    fi

    run_cmd gcc -shared -fPIC -o "$out_file" "$src_file"
    success "Fake DPI library: ${out_file}"
}

# ── Install nvim wrapper for bidirectional UE <-> nvim integration ──
install_nvim_wrapper() {
    local wrapper_src="${TEMPLATES_DIR}/nvim-wrapper.sh"
    local wrapper_dir="${BIN_DIR}/wrappers"
    local wrapper_dst="${wrapper_dir}/nvim"

    if [[ ! -f "$wrapper_src" ]]; then
        warn "nvim-wrapper.sh not found in templates — skipping wrapper install."
        return 1
    fi

    info "Installing nvim wrapper for UE integration..."
    run_cmd mkdir -p "$wrapper_dir"
    run_cmd cp "$wrapper_src" "$wrapper_dst"
    run_cmd chmod +x "$wrapper_dst"

    # Update PATH in .env so wrapper is available to UE
    local env_file="${INSTALL_BASE}/.env"
    if [[ -f "$env_file" ]]; then
        if ! grep -qF "${wrapper_dir}" "$env_file" 2>/dev/null; then
            info "Adding wrapper directory to PATH in ${env_file}..."
            if [[ $DRY_RUN -eq 0 ]]; then
                # Prepend wrapper dir to existing PATH line
                sed -i "s|export PATH=\"|export PATH=\"${wrapper_dir}:|" "$env_file"
            fi
        fi
    fi

    success "nvim wrapper installed: ${wrapper_dst}"
}

# ── Create launcher ──
create_launcher() {
    local version="$1"
    local launcher="${BIN_DIR}/ue-${version}"
    local engine_dir="${INSTALL_BASE}/${version}"

    info "Creating launcher with Wayland fix..."

    run_cmd mkdir -p "$BIN_DIR"

    run_cmd cat > "$launcher" << 'EOF'
#!/bin/bash
# Unreal Engine launcher
# Forces X11 backend on Wayland/Hyprland to avoid SDL3 UI issues
# Uses LD_PRELOAD to force 144 DPI for consistent UI scaling on HiDPI displays
# Auto-generated by install-unreal-engine.sh

unset QT_SCALE_FACTOR
unset QT_AUTO_SCREEN_SCALE_FACTOR
unset GDK_SCALE
unset GDK_DPI_SCALE
export SDL_VIDEODRIVER=x11

# Force X11 DPI to 144 via LD_PRELOAD to prevent UE Slate auto-scaling on HiDPI displays
# UE quantizes DPI into coarse steps (1.0, 1.5, 2.0, etc.); 144 gives 1.5x which looks good
FAKE_DPI_SO="${HOME}/UnrealEngine/bin/fake_dpi.so"
if [[ -f "$FAKE_DPI_SO" ]]; then
    export LD_PRELOAD="${FAKE_DPI_SO}${LD_PRELOAD:+:$LD_PRELOAD}"
fi

export GDK_SCALE=1
export QT_SCALE_FACTOR=1

# Prepend nvim wrapper to PATH so UE uses our wrapper instead of the real nvim binary.
# The wrapper handles dead socket detection and auto-respawn when opening files
# from the UE editor into a running (or freshly spawned) nvim instance.
WRAPPER_DIR="${HOME}/UnrealEngine/bin/wrappers"
if [[ -d "$WRAPPER_DIR" ]]; then
    export PATH="${WRAPPER_DIR}:${PATH}"
fi

# UE resolves .uproject paths relative to the engine dir, not the shell's cwd.
# Convert any relative .uproject paths to absolute so UE finds them correctly.
UE_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == *.uproject && ! "$arg" == /* ]]; then
        UE_ARGS+=("$(pwd)/$arg")
    else
        UE_ARGS+=("$arg")
    fi
done

EOF
    run_cmd cat >> "$launcher" << EOF
exec "${engine_dir}/Engine/Binaries/Linux/UnrealEditor" "\${UE_ARGS[@]}"
EOF

    run_cmd chmod +x "$launcher"
    success "Launcher created: ${launcher}"
}

# ── Create desktop entry ──
create_desktop_entry() {
    local version="$1"
    local launcher="${BIN_DIR}/ue-${version}"
    local desktop_file="${DESKTOP_DIR}/unreal-engine-${version}.desktop"

    info "Creating desktop entry..."

    run_cmd mkdir -p "$DESKTOP_DIR"

    run_cmd cat > "$desktop_file" << EOF
[Desktop Entry]
Type=Application
Name=Unreal Engine ${version}
Comment=The world's most open and advanced real-time 3D creation tool
Exec=${launcher} %F
Terminal=false
Icon=unreal-engine
MimeType=application/x-uproject;
Categories=AudioVideo;Development;Graphics;
EOF

    success "Desktop entry created: ${desktop_file}"
}

# ── Create/update .env file ──
create_env_file() {
    local version="$1"
    local env_file="${INSTALL_BASE}/.env"

    info "Creating/updating ${env_file}..."

    run_cmd cat > "$env_file" << EOF
# Unreal Engine environment
# Source this file from your shell config:
#   source \$HOME/UnrealEngine/.env
#
# To change the default 'ue' alias, edit the alias below or re-run install-unreal-engine.sh.

export PATH="${BIN_DIR}:\${PATH}"
alias ue='ue-${version}'
EOF

    success "Environment file updated: ${env_file}"
}

# ── Source .env in shell configs ──
source_env_in_shell() {
    local shell_rcs=()
    [[ -f "${HOME}/.bashrc" ]] && shell_rcs+=("${HOME}/.bashrc")
    [[ -f "${HOME}/.zshrc" ]] && shell_rcs+=("${HOME}/.zshrc")

    if [[ ${#shell_rcs[@]} -eq 0 ]]; then
        warn "No .bashrc or .zshrc found. Add this to your shell config manually:"
        echo "  source \$HOME/UnrealEngine/.env"
        return 0
    fi

    for rc_file in "${shell_rcs[@]}"; do
        if grep -qF "UnrealEngine/.env" "$rc_file" 2>/dev/null; then
            info "Already sourcing UnrealEngine/.env in ${rc_file}"
            continue
        fi

        info "Adding UnrealEngine/.env source to ${rc_file}..."
        run_cmd cat >> "$rc_file" << 'EOF'

# Unreal Engine environment (PATH + default ue alias)
[ -f "$HOME/UnrealEngine/.env" ] && source "$HOME/UnrealEngine/.env"
EOF
        success "Updated ${rc_file}"
    done
}

# ── Set default version (ask if replacing) ──
set_default_version() {
    local version="$1"
    local env_file="${INSTALL_BASE}/.env"

    if [[ -f "$env_file" ]]; then
        local current_default
        current_default=$(grep "^alias ue=" "$env_file" 2>/dev/null | sed "s/alias ue='//; s/'.*//" || true)

        if [[ -n "$current_default" && "$current_default" != "ue-${version}" ]]; then
            warn "Default 'ue' currently points to: ${current_default}"
            if [[ $DRY_RUN -eq 0 ]]; then
                read -rp "Set 'ue' to point to the new version (ue-${version})? [Y/n] " answer
                if [[ "$answer" =~ ^[Nn]$ ]]; then
                    info "Keeping existing default: ${current_default}"
                    return 0
                fi
            fi
        fi
    fi

    create_env_file "$version"
}

# ── Verify install ──
verify_install() {
    local version="$1"
    local editor="${INSTALL_BASE}/${version}/Engine/Binaries/Linux/UnrealEditor"

    if [[ -f "$editor" ]]; then
        success "UnrealEditor binary found: ${editor}"
        return 0
    else
        error "UnrealEditor binary not found at expected path: ${editor}"
        return 1
    fi
}

# ── Main ──
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Unreal Engine 5 — Binary Installer            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${YELLOW}║              [DRY-RUN MODE]                      ║${NC}"
    fi
    echo ""

    # Scan for zips
    local zip_files=()
    local versions=()
    find_ue_zips "$DOWNLOADS_DIR" zip_files versions

    if [[ ${#zip_files[@]} -eq 0 ]]; then
        error "No Linux_Unreal_Engine_*.zip found in ${DOWNLOADS_DIR}/"
        info "Please download the zip from Epic's website:"
        info "  https://www.unrealengine.com/linux"
        info ""
        info "You must be logged in with your Epic Games account."
        info "After downloading, place the zip in ${DOWNLOADS_DIR}/ and re-run this script."
        exit 1
    fi

    # Let user pick if multiple
    local selected_idx=0
    if [[ ${#zip_files[@]} -gt 1 ]]; then
        echo "Found multiple Unreal Engine zips:"
        local i
        for i in "${!zip_files[@]}"; do
            local size_human
            size_human=$(du -h "${zip_files[$i]}" | cut -f1)
            echo "  [$((i+1))] Linux_Unreal_Engine_${versions[$i]}.zip  (${size_human})"
        done
        echo ""

        local choice
        while true; do
            read -rp "Which version to install? [1-${#zip_files[@]}/q]: " choice
            [[ "$choice" == "q" || "$choice" == "Q" ]] && { info "Aborted."; exit 0; }
            if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#zip_files[@]} ]]; then
                selected_idx=$((choice - 1))
                break
            fi
            echo "Invalid choice. Please enter a number from 1 to ${#zip_files[@]}, or q to quit."
        done
    else
        info "Found: Linux_Unreal_Engine_${versions[0]}.zip"
        local answer
        read -rp "Install version ${versions[0]}? [Y/n] " answer
        [[ "$answer" =~ ^[Nn]$ ]] && { info "Aborted."; exit 0; }
    fi

    local selected_zip="${zip_files[$selected_idx]}"
    local selected_version="${versions[$selected_idx]}"

    info "Selected: Linux_Unreal_Engine_${selected_version}.zip"

    # Sanity check file size
    local file_size
    file_size=$(stat -c%s "$selected_zip" 2>/dev/null || echo 0)
    if [[ $file_size -lt $MIN_FILE_BYTES ]]; then
        error "File is suspiciously small (${file_size} bytes). Expected > 1 GB."
        error "The download may be incomplete or corrupted."
        exit 1
    fi
    info "File size: $((file_size / 1024 / 1024)) MB — looks good."

    # Check for existing install
    local existing_dir="${INSTALL_BASE}/${selected_version}"
    if [[ -d "$existing_dir" ]]; then
        warn "Version ${selected_version} is already installed at ${existing_dir}"
        read -rp "Re-install? This will replace the existing directory. [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            if [[ $DRY_RUN -eq 0 ]]; then
                rm -rf "$existing_dir"
            fi
        else
            info "Aborted."
            exit 0
        fi
    fi

    # Pre-flight
    check_disk_space 70

    # Check templates exist
    if [[ ! -d "$TEMPLATES_DIR" ]]; then
        error "Templates directory not found: ${TEMPLATES_DIR}"
        error "Ensure this script is run from the repository root."
        exit 1
    fi

    # Extract
    extract_release "$selected_zip" "$selected_version"

    # Post-install setup
    fix_permissions "$selected_version"
    compile_fake_dpi
    install_nvim_wrapper
    add_hyprland_windowrule
    install_icons "$TEMPLATES_DIR"
    install_mime "$TEMPLATES_DIR"
    create_launcher "$selected_version"
    create_desktop_entry "$selected_version"

    # Set UE as the default handler for .uproject files
    info "Setting Unreal Engine as default handler for .uproject files..."
    run_cmd xdg-mime default "${DESKTOP_DIR}/unreal-engine-${selected_version}.desktop" "application/x-uproject"

    set_default_version "$selected_version"
    source_env_in_shell
    verify_install "$selected_version"

    # Update desktop database
    run_cmd update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

    # Summary
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║              Installation Complete               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    success "Unreal Engine ${selected_version} installed to: ${INSTALL_BASE}/${selected_version}"
    info "Launch with: ue-${selected_version}"
    info "Default alias: ue (points to latest installed version)"
    info "Or find it in your application launcher."
    echo ""
    info "Wayland fix is baked in: SDL_VIDEODRIVER=x11 is set automatically."
    info "HiDPI fix: LD_PRELOAD forces 144 DPI for consistent UI scaling."
    echo ""
    info "nvim wrapper installed at: ${BIN_DIR}/wrappers/nvim"
    info "  Handles dead socket detection and auto-respawn for UE <-> nvim integration."
    echo ""
    info "The zip file remains in ${DOWNLOADS_DIR}/ — delete it manually when ready."
    echo ""
    info "Environment file: ${INSTALL_BASE}/.env"
    info "  Edit this file to change the default 'ue' alias."
    echo ""
    info "For Neovim integration, run:"
    info "  ./scripts/setup-ue-neovim.sh --engine-dir ${INSTALL_BASE}/${selected_version}"
    echo ""
}

main "$@"
