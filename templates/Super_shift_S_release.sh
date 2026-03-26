#!/bin/bash
set -Euo pipefail

Super_Shift_S_VERSION="12.27"

CONFIG_FILE="/etc/gaming-mode.conf"
[[ -f "$HOME/.gaming-mode.conf" ]] && CONFIG_FILE="$HOME/.gaming-mode.conf"
source "$CONFIG_FILE" 2>/dev/null || true
: "${PERFORMANCE_MODE:=enabled}"

NEEDS_RELOGIN=0
NEEDS_REBOOT=0

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

die() {
  local msg="$1"; local code="${2:-1}"
  echo "FATAL: $msg" >&2
  logger -t gaming-mode "Installation failed: $msg"
  exit "$code"
}

check_aur_helper_functional() {
  local helper="$1"
  if $helper --version &>/dev/null; then
    return 0
  else
    return 1
  fi
}

rebuild_yay() {
  info "Attempting to rebuild yay..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  pushd "$tmp_dir" >/dev/null || return 1
  if git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm; then
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    info "yay rebuilt successfully"
    return 0
  else
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    err "Failed to rebuild yay"
    return 1
  fi
}

validate_environment() {
  command -v pacman  >/dev/null || die "pacman required"
  command -v hyprctl >/dev/null || die "hyprctl required"
  [ -d "$HOME/.config/hypr" ] || die "Hyprland config directory not found (~/.config/hypr)"
}

check_package() { pacman -Qi "$1" &>/dev/null; }

is_amd_igpu_card() {
  local card_path="$1"
  local device_path="$card_path/device"
  local pci_slot=""
  [[ -L "$device_path" ]] && pci_slot=$(basename "$(readlink -f "$device_path")")
  [[ -z "$pci_slot" ]] && return 1
  local device_info=$(/usr/bin/lspci -s "$pci_slot" 2>/dev/null)
  if echo "$device_info" | grep -iqE 'renoir|cezanne|barcelo|rembrandt|phoenix|raphael|lucienne|picasso|raven|vega.*mobile|vega.*integrated|radeon.*graphics|yellow.*carp|green.*sardine|cyan.*skillfish|vangogh|van gogh|mendocino|hawk.*point|strix.*point|strix.*halo|krackan|sarlak'; then
    return 0
  fi
  if echo "$device_info" | grep -iqE 'radeon rx|navi [0-9]|navi[0-9]|vega 56|vega 64|radeon vii|radeon pro|firepro|polaris|ellesmere|baffin|lexa|radeon [0-9]{3,4}[^0-9]'; then
    return 1
  fi
  return 1
}

check_intel_only() {
  # Returns 0 (true) if system has Intel GPU but NO AMD/NVIDIA GPU
  # Returns 1 (false) if system has AMD/NVIDIA (Intel iGPU + dGPU is OK)
  local card_name driver driver_link
  local has_intel=false
  local has_amd_nvidia=false

  for card_path in /sys/class/drm/card[0-9]*; do
    card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    driver=$(basename "$(readlink "$driver_link")")

    case "$driver" in
      i915|xe)
        has_intel=true
        ;;
      nvidia|amdgpu)
        has_amd_nvidia=true
        ;;
    esac
  done

  # Block only if Intel exists and no AMD/NVIDIA exists
  if $has_intel && ! $has_amd_nvidia; then
    return 0  # Intel-only, block it
  fi
  return 1  # Has AMD/NVIDIA (or no Intel), allow it
}

detect_dgpu_monitors() {
  local -n _monitors=$1
  local -n _dgpu_card=$2
  local -n _dgpu_type=$3
  _monitors=()
  _dgpu_card=""
  _dgpu_type=""

  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if echo "$lspci_output" | grep -qi nvidia; then
    _dgpu_type="NVIDIA"
  elif echo "$lspci_output" | grep -iqE 'radeon rx|navi|vega 56|vega 64|radeon vii|radeon pro'; then
    _dgpu_type="AMD dGPU"
  fi

  for card_path in /sys/class/drm/card[0-9]*; do
    local card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    local driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    local driver=$(basename "$(readlink "$driver_link")")
    local is_dgpu=false

    case "$driver" in
      nvidia)
        is_dgpu=true
        [[ -z "$_dgpu_type" ]] && _dgpu_type="NVIDIA"
        ;;
      amdgpu)
        if ! is_amd_igpu_card "$card_path"; then
          is_dgpu=true
          [[ -z "$_dgpu_type" ]] && _dgpu_type="AMD dGPU"
        fi
        ;;
    esac

    if $is_dgpu; then
      _dgpu_card="$card_name"
      for connector in "$card_path"/"$card_name"-*/status; do
        [[ -f "$connector" ]] || continue
        local conn_dir=$(dirname "$connector")
        local conn_name=$(basename "$conn_dir")
        conn_name=${conn_name#card*-}
        [[ "$conn_name" == Writeback* ]] && continue
        local status=$(cat "$connector" 2>/dev/null)
        if [[ "$status" == "connected" ]]; then
          local resolution=""
          local mode_file="$conn_dir/modes"
          [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
          _monitors+=("$conn_name|$resolution")
        fi
      done
      break
    fi
  done
}

check_nvidia_kernel_params() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  NVIDIA KERNEL PARAMETER CHECK"
  echo "================================================================"
  echo ""

  if grep -qE "nvidia[-_]drm\.modeset=1" /proc/cmdline 2>/dev/null; then
    info "nvidia-drm.modeset=1 is already configured"
    return 0
  fi

  warn "nvidia-drm.modeset=1 is NOT SET - required for Gaming Mode!"
  echo ""

  local bootloader=""
  local config_file=""

  if [ -f /boot/limine.conf ]; then
    bootloader="limine"; config_file="/boot/limine.conf"
  elif [ -f /boot/limine/limine.conf ]; then
    bootloader="limine"; config_file="/boot/limine/limine.conf"
  elif [ -d /boot/loader/entries ]; then
    bootloader="systemd-boot"
  elif [ -f /etc/default/grub ]; then
    bootloader="grub"
  fi

  info "Detected bootloader: $bootloader"

  case "$bootloader" in
    limine)
      info "Limine config: $config_file"
      read -p "Add nvidia-drm.modeset=1 to Limine config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_limine_nvidia "$config_file"
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    systemd-boot)
      echo ""
      echo "  systemd-boot detected. You need to add nvidia-drm.modeset=1"
      echo "  to your boot entry in /boot/loader/entries/*.conf"
      echo ""
      show_manual_nvidia_instructions
      ;;
    grub)
      echo ""
      read -p "Add nvidia-drm.modeset=1 to GRUB config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_grub_nvidia
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    *)
      echo ""
      warn "Could not detect bootloader type"
      show_manual_nvidia_instructions
      ;;
  esac
}

configure_limine_nvidia() {
  local config_file="$1"

  info "Backing up Limine config..."
  sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup Limine config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to Limine cmdline..."

  if sudo sed -i '/^[[:space:]]*cmdline:/ s/$/ nvidia-drm.modeset=1/' "$config_file"; then
    if grep -q "nvidia-drm.modeset=1" "$config_file"; then
      info "Successfully added nvidia-drm.modeset=1 to Limine config"
      echo ""
      echo "  ✓ Limine config updated"
      echo "  ✓ Changes will take effect after reboot"
      echo ""
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter - please add manually"
      show_manual_nvidia_instructions
    fi
  else
    err "Failed to modify Limine config"
    show_manual_nvidia_instructions
  fi
}

configure_grub_nvidia() {
  local grub_default="/etc/default/grub"

  info "Backing up GRUB config..."
  sudo cp "$grub_default" "${grub_default}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup GRUB config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to GRUB..."

  if ! grep -q "nvidia-drm.modeset=1" "$grub_default"; then
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 nvidia-drm.modeset=1/' "$grub_default"

    if grep -q "nvidia-drm.modeset=1" "$grub_default"; then
      info "Regenerating GRUB config..."
      sudo grub-mkconfig -o /boot/grub/grub.cfg || {
        err "Failed to regenerate GRUB config"
        return 1
      }
      info "Successfully configured GRUB for NVIDIA"
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter to GRUB"
      show_manual_nvidia_instructions
    fi
  fi
}

show_manual_nvidia_instructions() {
  cat <<'MSG'
  Manual configuration required:
  Limine: Add nvidia-drm.modeset=1 to cmdline in /boot/limine.conf
  systemd-boot: Add to options in /boot/loader/entries/*.conf
  GRUB: Add to GRUB_CMDLINE_LINUX_DEFAULT, then run grub-mkconfig -o /boot/grub/grub.cfg
MSG
  warn "Gaming Mode may not work correctly without nvidia-drm.modeset=1"
}

install_nvidia_deckmode_env() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    info "No NVIDIA detected; skipping NVIDIA Deck-mode env."
    return 0
  fi

  local env_file="/etc/environment.d/90-nvidia-gamescope.conf"

  if [ -f "$env_file" ]; then
    info "NVIDIA gamescope env already present: $env_file"
    return 0
  fi

  info "Installing NVIDIA gamescope env (Deck-mode style)..."
  sudo mkdir -p /etc/environment.d

  sudo tee "$env_file" >/dev/null <<'EOF'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF

  info "Installed $env_file"
  NEEDS_RELOGIN=1
}

check_steam_dependencies() {
  info "Checking Steam dependencies for Arch Linux..."

  info "Force refreshing package database from all mirrors..."
  sudo pacman -Syy || die "Failed to refresh package database"

  echo ""
  echo "================================================================"
  echo "  SYSTEM UPDATE RECOMMENDED"
  echo "================================================================"
  echo ""
  echo "  It's recommended to upgrade your system before installing"
  echo "  gaming dependencies to avoid package version conflicts."
  echo ""
  read -p "Upgrade system now? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    info "Upgrading system..."
    sudo pacman -Syu --noconfirm || die "Failed to upgrade system"
  fi
  echo ""

  local -a missing_deps=()
  local -a optional_deps=()
  local multilib_enabled=false

  if ! command -v lspci >/dev/null 2>&1; then
    info "Installing pciutils for GPU detection..."
    sudo pacman -S --needed --noconfirm pciutils || die "Failed to install pciutils"
  fi

  if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
    multilib_enabled=true
    info "Multilib repository: enabled"
  else
    err "Multilib repository: NOT enabled (required for Steam)"
    missing_deps+=("multilib-repository")
  fi

  local -a core_deps=(
    "steam"
    "lib32-vulkan-icd-loader"
    "vulkan-icd-loader"
    "lib32-mesa"
    "mesa"
    "mesa-utils"
    "lib32-glibc"
    "lib32-gcc-libs"
    "lib32-libx11"
    "lib32-libxss"
    "lib32-alsa-plugins"
    "lib32-libpulse"
    "lib32-openal"
    "lib32-nss"
    "lib32-libcups"
    "lib32-sdl2-compat"
    "lib32-freetype2"
    "lib32-fontconfig"
    "lib32-libnm"
    "networkmanager"
    "gamemode"
    "lib32-gamemode"
    "ttf-liberation"
    "xdg-user-dirs"
    "kbd"
  )

  local gpu_vendor
  gpu_vendor=$(/usr/bin/lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

  local has_nvidia=false has_amd=false

  if echo "$gpu_vendor" | grep -qi nvidia; then
    has_nvidia=true
    info "Detected NVIDIA GPU"
  fi
  if echo "$gpu_vendor" | grep -iqE 'amd|radeon|advanced micro'; then
    has_amd=true
    info "Detected AMD GPU"
  fi
  if echo "$gpu_vendor" | grep -iq intel; then
    info "Detected Intel GPU; no Intel-specific drivers will be installed"
  fi

  local primary_gpu="unknown"
  if $has_nvidia; then
    primary_gpu="nvidia"
  elif $has_amd; then
    primary_gpu="amd"
  fi

  PRIMARY_GPU="$primary_gpu"
  info "Primary GPU selection: $PRIMARY_GPU"

  local -a gpu_deps=()

  if $has_nvidia; then
    gpu_deps+=(
      "nvidia-utils"
      "lib32-nvidia-utils"
      "nvidia-settings"
      "libva-nvidia-driver"
    )
    if ! check_package "nvidia" && ! check_package "nvidia-dkms" && ! check_package "nvidia-open-dkms"; then
      info "Note: You may need to install 'nvidia' or 'nvidia-open-dkms' kernel module"
      optional_deps+=("nvidia-open-dkms")
    fi
  fi

  if $has_amd; then
    gpu_deps+=(
      "vulkan-radeon"
      "lib32-vulkan-radeon"
      "libvdpau"
      "lib32-libvdpau"
    )
    ! check_package "xf86-video-amdgpu" && optional_deps+=("xf86-video-amdgpu")
  fi

  if ! $has_nvidia && ! $has_amd; then
    info "No NVIDIA/AMD GPU detected; installing AMD Vulkan drivers as fallback..."
    gpu_deps+=("vulkan-radeon" "lib32-vulkan-radeon")
  fi

  gpu_deps+=(
    "vulkan-tools"
    "vulkan-mesa-layers"
  )

  local -a recommended_deps=(
    "gamescope"
    "mangohud"
    "lib32-mangohud"
    "proton-ge-custom-bin"
    "udisks2"
  )

  info "Checking core Steam dependencies..."
  for dep in "${core_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking GPU-specific dependencies..."
  for dep in "${gpu_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking recommended dependencies..."
  for dep in "${recommended_deps[@]}"; do
    if ! check_package "$dep"; then
      optional_deps+=("$dep")
    fi
  done

  echo ""
  echo "================================================================"
  echo "  STEAM DEPENDENCY CHECK RESULTS"
  echo "================================================================"
  echo ""

  if [ "$multilib_enabled" = false ]; then
    echo "  CRITICAL: Multilib repository must be enabled!"
    echo ""
    echo "  To enable multilib, edit /etc/pacman.conf and uncomment:"
    echo "    [multilib]"
    echo "    Include = /etc/pacman.d/mirrorlist"
    echo ""
    read -p "Enable multilib repository now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      enable_multilib_repo
    else
      die "Multilib repository is required for Steam"
    fi
  fi

  local -a clean_missing=()
  for item in "${missing_deps[@]}"; do
    [[ -n "$item" && "$item" != "multilib-repository" ]] && clean_missing+=("$item")
  done
  missing_deps=("${clean_missing[@]+"${clean_missing[@]}"}")

  if ((${#missing_deps[@]})); then
    echo "  MISSING REQUIRED PACKAGES (${#missing_deps[@]}):"
    for dep in "${missing_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install missing required packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      info "Installing missing dependencies..."
      sudo pacman -S --needed --noconfirm "${missing_deps[@]}" || die "Failed to install Steam dependencies"
      info "Required dependencies installed successfully"
    else
      die "Missing required Steam dependencies"
    fi
  else
    info "All required Steam dependencies are installed!"
  fi

  echo ""
  # Flush any leftover stdin from previous interactive pacman commands
  read -t 0.1 -n 10000 discard 2>/dev/null || true
  if ((${#optional_deps[@]})); then
    echo "  RECOMMENDED PACKAGES (${#optional_deps[@]}):"
    for dep in "${optional_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install recommended packages? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Syncing package database before installing..."
      sudo pacman -Sy || warn "Failed to sync package database"

      info "Installing recommended packages..."
      # Check which packages are available in repos vs need AUR
      local -a failed_deps=()
      local -a pacman_deps=()
      for dep in "${optional_deps[@]}"; do
        if pacman -Si "$dep" &>/dev/null; then
          pacman_deps+=("$dep")
        else
          failed_deps+=("$dep")
        fi
      done
      if ((${#pacman_deps[@]})); then
        sudo pacman -S --needed --noconfirm "${pacman_deps[@]}" || warn "Some packages failed to install"
      fi

      # If some packages failed, try with an official Arch mirror as fallback
      if ((${#failed_deps[@]})); then
        local mirrorlist="/etc/pacman.d/mirrorlist"
        local fallback_mirror="Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
        local added_fallback=false

        if ! grep -q "geo.mirror.pkgbuild.com" "$mirrorlist" 2>/dev/null; then
          info "Some packages not found in current repos. Adding official Arch mirror..."
          sudo sed -i "1i $fallback_mirror" "$mirrorlist"
          sudo pacman -Syy || warn "Failed to sync with official mirror"
          added_fallback=true
        fi

        # Retry failed packages with updated database
        local -a aur_optional=()
        local -a retry_pacman=()
        for dep in "${failed_deps[@]}"; do
          if pacman -Si "$dep" &>/dev/null; then
            retry_pacman+=("$dep")
          else
            aur_optional+=("$dep")
          fi
        done
        if ((${#retry_pacman[@]})); then
          info "Found packages in official repos: ${retry_pacman[*]}"
          sudo pacman -S --needed --noconfirm "${retry_pacman[@]}" || warn "Some packages failed to install from official repos"
        fi

        # Remove the fallback mirror to restore original mirrorlist
        if $added_fallback; then
          sudo sed -i '/geo\.mirror\.pkgbuild\.com/d' "$mirrorlist"
          sudo pacman -Syy 2>/dev/null || true
          info "Removed fallback mirror, restored original mirrorlist"
        fi
      else
        local -a aur_optional=()
      fi

      if ((${#aur_optional[@]})); then
        echo ""
        info "The following packages are from AUR and need an AUR helper:"
        for dep in "${aur_optional[@]}"; do
          echo "    - $dep"
        done
        echo ""

        local aur_helper_available=""
        if command -v yay >/dev/null 2>&1; then
          if check_aur_helper_functional yay; then
            aur_helper_available="yay"
          else
            warn "yay is installed but broken (needs rebuild after system update)"
            read -p "Rebuild yay now? [Y/n]: " -n 1 -r
            echo
            REPLY=${REPLY:-Y}
            if [[ $REPLY =~ ^[Yy]$ ]] && rebuild_yay && check_aur_helper_functional yay; then
              aur_helper_available="yay"
            fi
          fi
        elif command -v paru >/dev/null 2>&1; then
          if check_aur_helper_functional paru; then
            aur_helper_available="paru"
          fi
        fi

        if [[ -n "$aur_helper_available" ]]; then
          read -p "Install AUR packages with $aur_helper_available? [y/N]: " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Install AUR packages one at a time so a single failure doesn't block others
            for dep in "${aur_optional[@]}"; do
              info "Installing $dep..."
              $aur_helper_available -S --needed --noconfirm "$dep" || warn "Failed to install $dep from AUR"
            done
          fi
        else
          info "No functional AUR helper found (yay/paru). Install manually if desired."
        fi
      fi
    fi
  else
    info "All recommended packages are already installed!"
  fi

  echo ""
  echo "================================================================"

  check_steam_config
}

enable_multilib_repo() {
  info "Enabling multilib repository..."

  sudo cp /etc/pacman.conf "/etc/pacman.conf.backup.$(date +%Y%m%d%H%M%S)" || die "Failed to backup pacman.conf"
  sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf || die "Failed to enable multilib"

  if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
    info "Multilib repository enabled successfully"
    echo ""
    info "Updating system to enable multilib packages..."
    read -p "Proceed with system upgrade? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      sudo pacman -Syu --noconfirm || die "Failed to update and upgrade system"
    else
      die "System upgrade required after enabling multilib"
    fi
  else
    die "Failed to enable multilib repository"
  fi
}

check_steam_config() {
  info "Checking Steam configuration..."

  local missing_groups=()

  if ! groups | grep -qw 'video'; then
    missing_groups+=("video")
  fi

  if ! groups | grep -qw 'input'; then
    missing_groups+=("input")
  fi

  if ! groups | grep -qw 'wheel'; then
    missing_groups+=("wheel")
  fi

  if ((${#missing_groups[@]})); then
    echo ""
    echo "================================================================"
    echo "  USER GROUP PERMISSIONS"
    echo "================================================================"
    echo ""
    echo "  Your user needs to be added to the following groups:"
    echo ""
    for group in "${missing_groups[@]}"; do
      case "$group" in
        video) echo "    - video  - Required for GPU hardware access" ;;
        input) echo "    - input  - Required for controller/gamepad support" ;;
        wheel) echo "    - wheel  - Required for NetworkManager control in gaming mode" ;;
      esac
    done
    echo ""
    echo "  NOTE: After adding groups, you MUST log out and log back in"
    echo ""
    read -p "Add user to ${missing_groups[*]} group(s)? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      local groups_to_add=$(IFS=,; echo "${missing_groups[*]}")
      info "Adding user to groups: $groups_to_add"
      if sudo usermod -aG "$groups_to_add" "$USER"; then
        info "Successfully added user to group(s): $groups_to_add"
        NEEDS_RELOGIN=1
      else
        err "Failed to add user to groups"
      fi
    fi
  else
    info "User is in video, input, and wheel groups - permissions OK"
  fi

  if [ -d "$HOME/.steam" ]; then
    info "Steam directory found at ~/.steam"
  fi

  if [ -d "$HOME/.local/share/Steam" ]; then
    info "Steam data directory found at ~/.local/share/Steam"
  fi

  if [ -f /proc/sys/vm/swappiness ]; then
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness)
    if [ "$swappiness" -gt 10 ]; then
      info "Tip: Consider lowering vm.swappiness to 10 for better gaming performance"
    fi
  fi

  local max_files
  max_files=$(ulimit -n 2>/dev/null || echo "0")
  if [ "$max_files" -lt 524288 ]; then
    info "Tip: Increase open file limit for esync support"
  fi
}

bootstrap_steam() {
  if ! check_package "steam"; then
    warn "Steam is not installed - skipping bootstrap"
    return 0
  fi

  if pgrep -x steam >/dev/null 2>&1; then
    warn "Steam is already running - skipping bootstrap"
    return 0
  fi

  local steam_dir="$HOME/.local/share/Steam"

  if [[ -d "$steam_dir/ubuntu12_32" ]]; then
    info "Steam is already bootstrapped"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  STEAM BOOTSTRAP & LOGIN"
  echo "================================================================"
  echo ""
  echo "  Steam needs to run once to download updates and set up its"
  echo "  runtime. This may take several minutes on first launch."
  echo ""
  echo "  Once Steam opens, please:"
  echo "    1. Wait for it to finish updating"
  echo "    2. Log in to your Steam account"
  echo "    3. Close Steam when you're done"
  echo ""
  echo "  The installer will continue automatically after Steam closes."
  echo ""
  read -p "Launch Steam now to bootstrap and log in? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping Steam bootstrap - you can run Steam manually later"
    return 0
  fi

  info "Launching Steam (first run may take a while)..."
  steam &>/dev/null &

  # Give Steam time to start up
  sleep 5

  if ! pgrep -x steam >/dev/null 2>&1; then
    warn "Steam does not appear to have started - check for errors"
    return 0
  fi

  info "Steam is running - log in and then close Steam to continue..."

  while pgrep -x steam >/dev/null 2>&1; do
    sleep 3
  done

  # Brief pause to let Steam fully clean up
  sleep 2

  if [[ -d "$steam_dir/ubuntu12_32" ]]; then
    info "Steam bootstrapped successfully"
  else
    warn "Steam closed but runtime files not found - Steam may need another run"
  fi

  info "Continuing installation..."
}

setup_performance_permissions() {
  local udev_rules_file="/etc/udev/rules.d/99-gaming-performance.rules"
  local sudoers_file="/etc/sudoers.d/gaming-mode-sysctl"
  local needs_setup=false

  if [ ! -f "$udev_rules_file" ] || [ ! -f "$sudoers_file" ]; then
    needs_setup=true
  fi

  if [ "$needs_setup" = false ]; then
    info "Performance permissions already configured"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  PERFORMANCE PERMISSIONS SETUP"
  echo "================================================================"
  echo ""
  echo "  To avoid sudo password prompts during gaming, we need to set"
  echo "  up permissions for CPU and GPU performance control."
  echo ""
  read -p "Set up passwordless performance controls? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping permissions setup"
    return 0
  fi

  if [ ! -f "$udev_rules_file" ]; then
    info "Creating udev rules for CPU/GPU performance control..."

    if sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/devices/system/cpu/%k/cpufreq/scaling_governor"
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/sh -c 'test -f /sys/devices/system/cpu/%k/cpufreq/energy_performance_preference && chmod 666 /sys/devices/system/cpu/%k/cpufreq/energy_performance_preference'"
SUBSYSTEM=="pci", DRIVER=="nvidia", ACTION=="bind", RUN+="/bin/sh -c 'test -f /sys%p/power/control && chmod 666 /sys%p/power/control'"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/device/power_dpm_force_performance_level"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_boost_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_min_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_max_freq_mhz"
UDEV_RULES
    then
      info "Udev rules created successfully"
      sudo udevadm control --reload-rules || true
      sudo udevadm trigger --subsystem-match=cpu --subsystem-match=drm || true
    fi
  fi

  if [[ -f "$sudoers_file" ]]; then
    info "Updating performance sudoers at $sudoers_file..."
    sudo rm -f "$sudoers_file"
  fi

  info "Creating sudoers rule for Performance Mode sysctl tuning..."

  local tee_output
  tee_output=$(sudo tee "$sudoers_file" << 'SUDOERS_PERF' 2>&1
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_migration_cost_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_min_granularity_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_latency_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.split_lock_mitigate=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.max_map_count=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.compaction_proactiveness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.nmi_watchdog=*
%video ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS_PERF
)
  local tee_exit=$?

  if [[ $tee_exit -eq 0 ]]; then
    sudo chmod 0440 "$sudoers_file"
    info "Performance sudoers created successfully"
  else
    err "Failed to create performance sudoers file (exit code: $tee_exit)"
  fi

  local memlock_file="/etc/security/limits.d/99-gaming-memlock.conf"
  if [ ! -f "$memlock_file" ]; then
    info "Creating memlock limits for gaming performance..."
    if sudo tee "$memlock_file" > /dev/null << 'MEMLOCKCONF'
* soft memlock 2147484
* hard memlock 2147484
MEMLOCKCONF
    then
      info "Memlock limits configured (2GB)"
    fi
  fi

  local pipewire_conf_dir="/etc/pipewire/pipewire.conf.d"
  local pipewire_conf="$pipewire_conf_dir/10-gaming-latency.conf"
  if [ ! -f "$pipewire_conf" ]; then
    info "Creating PipeWire low-latency audio configuration..."
    sudo mkdir -p "$pipewire_conf_dir"
    if sudo tee "$pipewire_conf" > /dev/null << 'PIPEWIRECONF'
context.properties = {
    default.clock.min-quantum = 256
}
PIPEWIRECONF
    then
      info "PipeWire gaming latency configured"
    fi
  fi

  info "Performance permissions configured"
  return 0
}

setup_shader_cache() {
  local env_file="/etc/environment.d/99-shader-cache.conf"

  if [ -f "$env_file" ]; then
    info "Shader cache configuration already exists"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  SHADER CACHE OPTIMIZATION"
  echo "================================================================"
  echo ""
  echo "  Configuring shader cache sizes for better gaming performance."
  echo "  This reduces stuttering in games by caching compiled shaders."
  echo ""
  read -p "Configure shader cache optimization? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping shader cache configuration"
    return 0
  fi

  info "Creating shader cache configuration..."
  sudo mkdir -p /etc/environment.d || { warn "Failed to create /etc/environment.d"; return 0; }
  local tmp_shader
  tmp_shader=$(mktemp) || { warn "Failed to create temp file"; return 0; }

  cat > "$tmp_shader" << 'SHADERCACHE'
MESA_SHADER_CACHE_MAX_SIZE=12G
MESA_SHADER_CACHE_DISABLE_CLEANUP=1
RADV_PERFTEST=gpl
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=12884901888
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
DXVK_STATE_CACHE=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SHADERCACHE

  if sudo cp "$tmp_shader" "$env_file"; then
    rm -f "$tmp_shader"
    sudo chmod 644 "$env_file"
    info "Shader cache configured for all GPUs (AMD/NVIDIA + Proton)"
  else
    rm -f "$tmp_shader"
    warn "Failed to create shader cache configuration"
  fi
}

setup_fcitx_silence() {
  local env_dir="$HOME/.config/environment.d"
  local env_file="$env_dir/90-fcitx-wayland.conf"

  if [[ ! -f "$env_file" ]] || ! grep -q "FCITX_NO_WAYLAND_DIAGNOSE=1" "$env_file" 2>/dev/null; then
    mkdir -p "$env_dir" || return 0
    cat > "$env_file" <<'EOF'
FCITX_NO_WAYLAND_DIAGNOSE=1
EOF
    info "Created fcitx Wayland silence config"
    NEEDS_RELOGIN=1
  fi
}

setup_ananicy() {
  if check_package "ananicy-cpp" || check_package "ananicy-cpp-git"; then
    info "ananicy-cpp already installed"
    if ! systemctl is-enabled --quiet ananicy-cpp.service 2>/dev/null; then
      sudo systemctl enable --now ananicy-cpp.service 2>/dev/null && info "ananicy-cpp service enabled"
    fi
    # Still check for rules
    if check_package "cachyos-ananicy-rules-git" || check_package "cachyos-ananicy-rules"; then
      return 0
    fi
    info "ananicy-cpp is installed but CachyOS rules are missing, installing rules..."
  else
    echo ""
    echo "================================================================"
    echo "  PROCESS PRIORITY DAEMON (ananicy-cpp)"
    echo "================================================================"
    echo ""
    echo "  ananicy-cpp automatically adjusts process priorities so games"
    echo "  get more CPU time and background tasks don't cause stutter."
    echo ""
    read -p "Install ananicy-cpp? [Y/n]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Nn]$ ]]; then
      info "Skipping ananicy-cpp"
      return 0
    fi

    # Install ananicy-cpp from official repos (pre-built binary)
    info "Installing ananicy-cpp from official repos..."
    sudo pacman -S --needed --noconfirm ananicy-cpp || {
      warn "Failed to install ananicy-cpp"
      return 0
    }
  fi

  # Install CachyOS rules from AUR
  local aur_helper=""
  if command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay; then
    aur_helper="yay"
  elif command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru; then
    aur_helper="paru"
  fi

  if [[ -z "$aur_helper" ]]; then
    warn "No AUR helper found. Install CachyOS rules manually: yay -S cachyos-ananicy-rules-git"
  else
    info "Installing CachyOS ananicy rules..."
    local aur_flags=(--needed --noconfirm)
    if [[ "$aur_helper" == "yay" ]]; then
      aur_flags+=(--answeredit None --answerclean None --answerdiff None)
    elif [[ "$aur_helper" == "paru" ]]; then
      aur_flags+=(--skipreview)
    fi
    $aur_helper -S "${aur_flags[@]}" cachyos-ananicy-rules-git || {
      warn "Failed to install CachyOS ananicy rules from AUR"
    }
  fi

  sudo systemctl enable --now ananicy-cpp.service 2>/dev/null && info "ananicy-cpp service enabled and started"
}

configure_elephant_launcher() {
  local cfg="$HOME/.config/elephant/desktopapplications.toml"
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  if ! command -v uwsm-app >/dev/null 2>&1; then
    return 0
  fi

  if grep -q '^launch_prefix[[:space:]]*=[[:space:]]*"uwsm-app --"' "$cfg" 2>/dev/null; then
    return 0
  fi

  if grep -q '^launch_prefix[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i 's|^launch_prefix[[:space:]]*=.*|launch_prefix = "uwsm-app --"|' "$cfg"
  else
    echo 'launch_prefix = "uwsm-app --"' >> "$cfg"
  fi
  info "Configured Elephant desktopapplications launch_prefix (uwsm-app)"
  restart_elephant_walker
}

restart_elephant_walker() {
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    return 0
  fi
  if command -v omarchy-restart-walker >/dev/null 2>&1; then
    omarchy-restart-walker >/dev/null 2>&1 || true
    return 0
  fi
  systemctl --user restart elephant.service >/dev/null 2>&1 || true
  systemctl --user restart app-walker@autostart.service >/dev/null 2>&1 || true
}

setup_requirements() {
  local -a required_packages=("steam" "gamescope" "mangohud" "python" "python-evdev" "libcap" "gamemode" "curl" "pciutils" "ntfs-3g" "xcb-util-cursor")
  local -a packages_to_install=()
  for pkg in "${required_packages[@]}"; do
    check_package "$pkg" || packages_to_install+=("$pkg")
  done

  if ((${#packages_to_install[@]})); then
    info "The following packages are required: ${packages_to_install[*]}"
    read -p "Install missing packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      sudo pacman -S --needed "${packages_to_install[@]}" || die "package install failed"
    else
      die "Required packages missing - cannot continue"
    fi
  else
    info "All required packages present."
  fi

  setup_performance_permissions
  setup_fcitx_silence
  setup_shader_cache
  setup_ananicy
  configure_elephant_launcher

  if [[ "${PERFORMANCE_MODE,,}" == "enabled" ]] && command -v gamescope >/dev/null 2>&1; then
    if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
      echo ""
      echo "================================================================"
      echo "  GAMESCOPE CAPABILITY REQUEST"
      echo "================================================================"
      echo ""
      echo "  Performance mode requires granting cap_sys_nice to gamescope."
      echo ""
      read -p "Grant cap_sys_nice to gamescope? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)" || warn "Failed to set capability"
        info "Capability granted to gamescope"
      fi
    fi
  fi
}

setup_session_switching() {
  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING SETUP (Hyprland <-> Gamescope)"
  echo "  Using ChimeraOS gamescope-session packages"
  echo "================================================================"
  echo ""

  # Intel-only check - bail out early (Intel iGPU + AMD/NVIDIA dGPU is OK)
  if check_intel_only; then
    echo ""
    echo "  ███╗   ██╗ ██████╗     ██████╗ ██╗ ██████╗███████╗"
    echo "  ████╗  ██║██╔═══██╗    ██╔══██╗██║██╔════╝██╔════╝"
    echo "  ██╔██╗ ██║██║   ██║    ██║  ██║██║██║     █████╗  "
    echo "  ██║╚██╗██║██║   ██║    ██║  ██║██║██║     ██╔══╝  "
    echo "  ██║ ╚████║╚██████╔╝    ██████╔╝██║╚██████╗███████╗"
    echo "  ╚═╝  ╚═══╝ ╚═════╝     ╚═════╝ ╚═╝ ╚═════╝╚══════╝"
    echo ""
    err "NO DICE CHICAGO - INTEL DETECTED"
    echo ""
    echo "  This setup does not support Intel GPUs (iGPU or Arc)."
    echo "  Gaming Mode requires AMD or NVIDIA graphics."
    echo ""
    exit 1
  fi

  echo "  This will:"
  echo "    - Install gamescope-session-git and gamescope-session-steam-git from AUR"
  echo "    - Configure Super+Shift+S to switch to Gaming Mode"
  echo "    - Configure Steam's 'Exit to Desktop' to return to Hyprland"
  echo ""
  read -p "Set up session switching? [Y/n]: " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping session switching setup"
    return 0
  fi

  local current_user="${SUDO_USER:-$USER}"
  local user_home
  user_home=$(eval echo "~$current_user")

  local monitor_width=1920
  local monitor_height=1080
  local monitor_refresh=60
  local monitor_output=""

  local -a dgpu_monitors=()
  local dgpu_card=""
  local dgpu_type=""
  detect_dgpu_monitors dgpu_monitors dgpu_card dgpu_type

  if [[ -z "$dgpu_card" ]]; then
    if [[ "$dgpu_type" == "NVIDIA" ]]; then
      err "NVIDIA GPU detected but no DRM card found!"
      echo ""
      echo "  This usually means nvidia-drm.modeset=1 is not set."
      echo "  The installer will configure this - please complete the setup"
      echo "  and REBOOT before running this section again."
      echo ""
      NEEDS_REBOOT=1
      return 1
    fi
    # No dGPU - check for APU
    local apu_card=""
    local apu_monitors=()
    local card_name driver_link driver conn_dir conn_name status resolution mode_file

    for card_path in /sys/class/drm/card[0-9]*; do
      card_name=$(basename "$card_path")
      [[ "$card_name" == render* ]] && continue
      driver_link="$card_path/device/driver"
      [[ -L "$driver_link" ]] || continue
      driver=$(basename "$(readlink "$driver_link")")

      if [[ "$driver" == "amdgpu" ]] && is_amd_igpu_card "$card_path"; then
        apu_card="$card_name"
        # Find monitors connected to APU
        for connector in "$card_path"/"$card_name"-*/status; do
          [[ -f "$connector" ]] || continue
          conn_dir=$(dirname "$connector")
          conn_name=$(basename "$conn_dir")
          conn_name=${conn_name#card*-}
          [[ "$conn_name" == Writeback* ]] && continue
          status=$(cat "$connector" 2>/dev/null)
          if [[ "$status" == "connected" ]]; then
            resolution=""
            mode_file="$conn_dir/modes"
            [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
            apu_monitors+=("$conn_name|$resolution")
          fi
        done
        break
      fi
    done

    if [[ -n "$apu_card" && ${#apu_monitors[@]} -gt 0 ]]; then
      echo ""
      info "No discrete GPU found, but detected AMD APU ($apu_card)"
      echo ""
      echo "  This system has an AMD APU which can run Gaming Mode."
      echo "  Detected monitors: ${#apu_monitors[@]}"
      echo ""
      read -p "  Set up Gaming Mode for APU? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        # Use APU as the gaming GPU
        dgpu_card="$apu_card"
        dgpu_type="AMD APU"
        dgpu_monitors=("${apu_monitors[@]}")
        info "Configuring Gaming Mode for AMD APU"
      else
        info "Skipping APU Gaming Mode setup"
        return 0
      fi
    else
      err "No discrete GPU (dGPU) or AMD APU found!"
      echo "  Gaming mode requires a supported GPU with a connected display."
      return 1
    fi
  fi

  info "Found $dgpu_type on $dgpu_card"

  if [[ ${#dgpu_monitors[@]} -eq 0 ]]; then
    err "No monitors connected to dGPU!"
    echo ""
    echo "  Gaming mode requires a monitor connected to the discrete GPU."
    echo "  Please connect an external monitor to your dGPU port (HDMI/DP/USB-C)"
    echo "  and re-run this installer."
    echo ""
    return 1
  fi

  if [[ ${#dgpu_monitors[@]} -eq 1 ]]; then
    local entry="${dgpu_monitors[0]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  else
    echo ""
    echo "  Multiple monitors connected to $dgpu_type:"
    local i=1
    for entry in "${dgpu_monitors[@]}"; do
      local name="${entry%%|*}"
      local res="${entry##*|}"
      echo "    $i) $name ${res:+($res)}"
      ((i++))
    done
    echo ""
    read -p "Select monitor for Gaming Mode [1-${#dgpu_monitors[@]}]: " selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#dgpu_monitors[@]})); then
      selection=1
    fi
    local entry="${dgpu_monitors[$((selection-1))]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  fi

  info "Selected dGPU display: ${monitor_output} (${monitor_width}x${monitor_height}@${monitor_refresh}Hz)"

  info "Checking for old custom session files to clean up..."

  local -a old_files=(
    "/usr/bin/gamescope-session"
    "/usr/share/wayland-sessions/gamescope-session.desktop"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-update"
    "/usr/bin/steamos-select-branch"
    "/usr/bin/steamos-session-select"
  )

  local cleaned=false
  for old_file in "${old_files[@]}"; do
    if [[ -f "$old_file" ]]; then
      info "Removing old file: $old_file"
      sudo rm -f "$old_file" && cleaned=true
    fi
  done

  if $cleaned; then
    info "Old custom session files removed"
  else
    info "No old files to clean up"
  fi

  info "Checking for ChimeraOS gamescope-session packages..."

  local -a aur_packages=()
  local -a packages_to_remove=()

  if ! check_package "gamescope-session-git" && ! check_package "gamescope-session"; then
    aur_packages+=("gamescope-session-git")
  fi

  local steam_scripts_missing=false
  local -a required_steam_scripts=(
    "/usr/bin/steamos-session-select"
    "/usr/bin/steamos-update"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-select-branch"
  )

  for script in "${required_steam_scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
      steam_scripts_missing=true
      break
    fi
  done

  if ! check_package "gamescope-session-steam-git"; then
    if check_package "gamescope-session-steam"; then
      warn "gamescope-session-steam (non-git) is installed but missing Steam compatibility scripts"
      info "The -git version from ChimeraOS includes required scripts:"
      info "  - steamos-session-select, steamos-update, jupiter-biosupdate, steamos-select-branch"
      packages_to_remove+=("gamescope-session-steam")
    fi
    aur_packages+=("gamescope-session-steam-git")
  elif $steam_scripts_missing; then
    warn "gamescope-session-steam-git is installed but Steam compatibility scripts are missing!"
    info "Will reinstall package to restore missing files:"
    for script in "${required_steam_scripts[@]}"; do
      if [[ ! -f "$script" ]]; then
        info "  - Missing: $script"
      fi
    done
    packages_to_remove+=("gamescope-session-steam-git")
    aur_packages+=("gamescope-session-steam-git")
  fi

  if ((${#aur_packages[@]})); then
    echo ""
    echo "  The following AUR packages are required for ChimeraOS session:"
    for pkg in "${aur_packages[@]}"; do
      echo "    - $pkg"
    done
    if ((${#packages_to_remove[@]})); then
      echo ""
      echo "  The following packages need to be replaced:"
      for pkg in "${packages_to_remove[@]}"; do
        echo "    - $pkg (will be removed)"
      done
    fi
    echo ""

    local aur_helper=""
    if command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay; then
      aur_helper="yay"
    elif command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru; then
      aur_helper="paru"
    fi

    if [[ -n "$aur_helper" ]]; then
      read -p "Install ChimeraOS session packages with $aur_helper? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if ((${#packages_to_remove[@]})); then
          info "Removing conflicting packages: ${packages_to_remove[*]}"
          sudo pacman -Rns --noconfirm "${packages_to_remove[@]}" || {
            warn "Failed to remove old packages, trying to continue anyway..."
          }
        fi

        # Clean stale AUR cache to avoid "is not a clone of" errors
        # when upstream source URLs change
        for pkg in "${aur_packages[@]}"; do
          local cache_dir="$HOME/.cache/$aur_helper/$pkg"
          if [[ -d "$cache_dir" ]]; then
            info "Clearing stale AUR cache for $pkg..."
            rm -rf "$cache_dir"
          fi
        done

        info "Installing ChimeraOS gamescope-session packages..."
        local aur_flags=(--needed --noconfirm)
        if [[ "$aur_helper" == "yay" ]]; then
          aur_flags+=(--answeredit None --answerclean None --answerdiff None)
        elif [[ "$aur_helper" == "paru" ]]; then
          aur_flags+=(--skipreview)
        fi
        $aur_helper -S "${aur_flags[@]}" "${aur_packages[@]}" || {
          err "Failed to install gamescope-session packages"
          warn "You may need to install them manually: $aur_helper -S ${aur_packages[*]}"
        }
      fi
    else
      warn "No AUR helper found (yay/paru). Please install manually:"
      if ((${#packages_to_remove[@]})); then
        echo "    sudo pacman -Rns ${packages_to_remove[*]}"
      fi
      echo "    yay -S ${aur_packages[*]}"
      echo ""
      read -p "Press Enter to continue after installing, or Ctrl+C to abort..."
    fi
  else
    info "ChimeraOS gamescope-session packages already installed (correct -git versions)"
  fi

  info "Setting up NetworkManager integration..."
  if systemctl is-active --quiet iwd; then
    info "Detected iwd is active - configuring NetworkManager to use iwd backend..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/10-iwd-backend.conf > /dev/null << 'NM_IWD_CONF'
[device]
wifi.backend=iwd
wifi.scan-rand-mac-address=no

[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=false

[connection]
connection.autoconnect-slaves=0
NM_IWD_CONF
    info "Created NetworkManager iwd backend configuration"
  fi

  if systemctl is-active --quiet systemd-networkd; then
    info "Detected systemd-networkd - configuring NetworkManager to avoid conflicts..."
    sudo tee /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf > /dev/null << 'NM_UNMANAGED'
[keyfile]
unmanaged-devices=interface-name:en*;interface-name:eth*
NM_UNMANAGED
    info "Configured NetworkManager to not manage ethernet interfaces"
  fi

  local nm_start_script="/usr/local/bin/gamescope-nm-start"
  sudo tee "$nm_start_script" > /dev/null << 'NM_START'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"

log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if ! systemctl is-active --quiet NetworkManager.service; then
    log "Starting NetworkManager service..."
    systemctl start NetworkManager.service
    if [ $? -eq 0 ]; then
        touch "$NM_MARKER"
        log "NetworkManager started successfully"
    else
        log "ERROR: Failed to start NetworkManager"
        exit 1
    fi
    log "Waiting for NetworkManager to initialize..."
    for i in {1..20}; do
        if nmcli general status &>/dev/null; then
            log "NetworkManager ready after ${i} attempts"
            break
        fi
        sleep 0.5
    done
    if nmcli general status 2>/dev/null | grep -q "connected"; then
        log "Network connected and ready"
    else
        log "WARNING: NetworkManager running but not connected"
    fi
else
    log "NetworkManager already running"
fi
nmcli general status 2>/dev/null || log "WARNING: nmcli status check failed"
NM_START
  sudo chmod +x "$nm_start_script"

  local nm_stop_script="/usr/local/bin/gamescope-nm-stop"
  sudo tee "$nm_stop_script" > /dev/null << 'NM_STOP'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if [ -f "$NM_MARKER" ]; then
    rm -f "$NM_MARKER"
    if systemctl is-active --quiet NetworkManager.service; then
        log "Stopping NetworkManager service..."
        systemctl stop NetworkManager.service 2>/dev/null || true
        sleep 1
    fi

    # Restart iwd to restore WiFi connection (must restart, not just start,
    # because iwd may be "active" but not managing the interface while NM had control)
    log "Restarting iwd to restore WiFi..."
    systemctl restart iwd.service 2>/dev/null || true
    sleep 3

    # Find the wireless interface dynamically
    WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
    fi

    if [ -n "$WIFI_IFACE" ]; then
        # Verify WiFi restoration (iwd auto-connects to known networks)
        if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
            log "WiFi restored on $WIFI_IFACE"
        else
            log "Triggering WiFi scan on $WIFI_IFACE..."
            iwctl station "$WIFI_IFACE" scan 2>/dev/null || true
            sleep 3
            if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
                log "WiFi connected on $WIFI_IFACE after scan"
            else
                log "WiFi on $WIFI_IFACE may need manual reconnection via iwctl"
            fi
        fi
    else
        log "No wireless interface found - skipping WiFi verification"
    fi
else
    log "No marker file found - NetworkManager was not started by gaming session"
fi
NM_STOP
  sudo chmod +x "$nm_stop_script"
  info "Created NetworkManager start/stop scripts"

  local steam_mount_script="/usr/local/bin/steam-library-mount"
  info "Creating Steam library drive mount script..."
  sudo tee "$steam_mount_script" > /dev/null << 'STEAM_MOUNT'
#!/bin/bash
LOG_TAG="steam-library-mount"
MOUNT_BASE="/run/media/$USER"

log() { logger -t "$LOG_TAG" "$*"; }

check_steam_library() {
    local mount_point="$1"
    if [[ -d "$mount_point/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary" ]] || \
       [[ -f "$mount_point/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/steamapps/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/SteamLibrary/libraryfolder.vdf" ]]; then
        return 0
    fi
    return 1
}

handle_device() {
    local device="$1"
    local part_name
    part_name=$(basename "$device")

    log "Checking device: $device"

    if findmnt -n "$device" &>/dev/null; then
        local existing_mount
        existing_mount=$(findmnt -n -o TARGET "$device" 2>/dev/null)
        if [[ -n "$existing_mount" ]] && check_steam_library "$existing_mount"; then
            log "Steam library already mounted at $existing_mount"
        else
            log "Device $device mounted at $existing_mount (no Steam library)"
        fi
        return
    fi

    [[ "$device" =~ [0-9]$ ]] || { log "Skipping whole disk: $device"; return; }

    local fstype
    fstype=$(lsblk -n -o FSTYPE --nodeps "$device" 2>/dev/null)
    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs|ntfs|vfat|exfat|f2fs) ;;
        crypto_LUKS) log "Skipping encrypted: $device"; return ;;
        swap) log "Skipping swap: $device"; return ;;
        "") log "Skipping $device - no filesystem"; return ;;
        *) log "Skipping $device - unsupported filesystem: $fstype"; return ;;
    esac

    if ! command -v udisksctl &>/dev/null; then
        log "udisksctl not found - cannot mount $device"
        return
    fi

    log "Attempting to mount $device..."
    local mount_output
    mount_output=$(udisksctl mount -b "$device" --no-user-interaction 2>&1)
    local mount_rc=$?

    if [[ $mount_rc -ne 0 ]]; then
        log "Could not mount $device: $mount_output"
        return
    fi

    local mount_point
    mount_point=$(findmnt -n -o TARGET "$device" 2>/dev/null)

    if [[ -z "$mount_point" ]]; then
        log "Could not determine mount point for $device"
        return
    fi

    if check_steam_library "$mount_point"; then
        log "Steam library found on $device at $mount_point - keeping mounted"
    else
        log "No Steam library on $device - unmounting"
        udisksctl unmount -b "$device" --no-user-interaction 2>/dev/null
    fi
}

log "Starting Steam library drive monitor..."

shopt -s nullglob
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]*; do
    [[ -b "$dev" ]] && handle_device "$dev"
done
shopt -u nullglob

log "Initial device scan complete, watching for new devices..."

udevadm monitor --kernel --subsystem-match=block 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^KERNEL.*[[:space:]]add[[:space:]]+.*/([^/[:space:]]+)[[:space:]]+\(block\)$ ]]; then
        dev_name="${BASH_REMATCH[1]}"
        dev_path="/dev/$dev_name"
        if [[ "$dev_name" =~ [0-9]$ ]] && [[ -b "$dev_path" ]]; then
            sleep 1
            handle_device "$dev_path"
        fi
    fi
done
STEAM_MOUNT
  sudo chmod +x "$steam_mount_script"
  info "Created $steam_mount_script"

  local polkit_rules="/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"

  if sudo test -f "$polkit_rules"; then
    info "Polkit rules already exist at $polkit_rules"
  else
    info "Creating Polkit rules for NetworkManager D-Bus access..."

    local polkit_output
    polkit_output=$(sudo tee "$polkit_rules" << 'POLKIT_RULES' 2>&1
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
)
    local polkit_exit=$?

    if [[ $polkit_exit -eq 0 ]]; then
      sudo chmod 644 "$polkit_rules"
      info "Polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create polkit rules file (exit code: $polkit_exit)"
    fi
  fi

  local udisks_polkit="/etc/polkit-1/rules.d/50-udisks-gaming.rules"

  if sudo test -f "$udisks_polkit"; then
    info "Udisks2 polkit rules already exist at $udisks_polkit"
  else
    info "Creating Polkit rules for external drive auto-mount..."
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee "$udisks_polkit" > /dev/null << 'UDISKS_POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
UDISKS_POLKIT

    if [[ $? -eq 0 ]]; then
      sudo chmod 644 "$udisks_polkit"
      info "Udisks2 polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create udisks2 polkit rules"
    fi
  fi

  info "Creating gamescope-session-plus configuration..."
  local env_dir="${user_home}/.config/environment.d"
  local gamescope_conf="${env_dir}/gamescope-session-plus.conf"

  mkdir -p "$env_dir"

  local output_connector=""
  [[ -n "$monitor_output" ]] && output_connector="OUTPUT_CONNECTOR=$monitor_output"

  local is_nvidia=false
  local nvidia_device_id=""
  if [[ "$dgpu_type" == "NVIDIA" ]]; then
    is_nvidia=true
    nvidia_device_id=$(/usr/bin/lspci -nn | grep -i nvidia | grep -oP '\[10de:\K[0-9a-fA-F]+' | head -1)
    if [ "$monitor_width" -gt 2560 ]; then
      monitor_width=2560
    fi
    if [ "$monitor_height" -gt 1440 ]; then
      monitor_height=1440
    fi
  fi

  if $is_nvidia; then
    local vulkan_adapter=""
    [[ -n "$nvidia_device_id" ]] && vulkan_adapter="VULKAN_ADAPTER=10de:${nvidia_device_id}"
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
${vulkan_adapter}
GBM_BACKEND=nvidia-drm
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  else
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
ADAPTIVE_SYNC=1
ENABLE_GAMESCOPE_HDR=1
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  fi

  info "Created $gamescope_conf"

  info "Creating NVIDIA gamescope wrapper..."
  local nvidia_wrapper_dir="/usr/local/lib/gamescope-nvidia"
  local nvidia_wrapper="${nvidia_wrapper_dir}/gamescope"

  sudo mkdir -p "$nvidia_wrapper_dir"
  sudo tee "$nvidia_wrapper" > /dev/null << 'NVIDIA_WRAPPER'
#!/bin/bash
EXTRA_ARGS=""
if /usr/bin/gamescope --help 2>&1 | grep -q "force-composition"; then
    EXTRA_ARGS="--force-composition"
fi
exec /usr/bin/gamescope $EXTRA_ARGS "$@"
NVIDIA_WRAPPER

  sudo chmod +x "$nvidia_wrapper"
  info "Created $nvidia_wrapper"

  info "Creating NetworkManager session wrapper..."
  local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"

  sudo tee "$nm_wrapper" > /dev/null << 'NM_WRAPPER'
#!/bin/bash
log() { logger -t gamescope-wrapper "$*"; echo "$*"; }

enable_performance_mode() {
    log "Enabling performance mode..."

    # Save original values for restore
    ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "powersave")
    ORIG_EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "balance_performance")
    ORIG_SPLIT_LOCK=$(sysctl -n kernel.split_lock_mitigate 2>/dev/null || echo "")
    ORIG_MAX_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo "1048576")
    ORIG_COMPACTION=$(sysctl -n vm.compaction_proactiveness 2>/dev/null || echo "20")
    ORIG_NMI=$(sysctl -n kernel.nmi_watchdog 2>/dev/null || echo "1")
    ORIG_THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "always")

    # Set CPU governor to performance
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null && log "CPU governor set to performance"
        break  # Log only once
    done
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null
    done

    # AMD pstate: set energy performance preference to performance
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        if [[ -w "$epp" ]]; then
            echo performance > "$epp" 2>/dev/null
        fi
    done
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        log "AMD pstate EPP set to performance"
    fi

    # Kernel tuning: disable split lock mitigation (prevents stalls in some Proton games)
    [[ -n "$ORIG_SPLIT_LOCK" ]] && sudo -n /usr/bin/sysctl -w kernel.split_lock_mitigate=0 2>/dev/null && log "Split lock mitigation disabled"

    # Increase max memory map areas (prevents crashes in heavy Proton titles)
    sudo -n /usr/bin/sysctl -w vm.max_map_count=2147483642 2>/dev/null && log "vm.max_map_count increased"

    # Disable proactive memory compaction (reduces latency spikes)
    sudo -n /usr/bin/sysctl -w vm.compaction_proactiveness=0 2>/dev/null && log "Proactive compaction disabled"

    # Disable NMI watchdog (frees a hardware perf counter)
    sudo -n /usr/bin/sysctl -w kernel.nmi_watchdog=0 2>/dev/null && log "NMI watchdog disabled"

    # Set transparent hugepages to madvise (avoids background compaction stalls)
    echo madvise | sudo -n /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 && log "THP set to madvise"

    # NVIDIA dGPU performance mode
    if command -v nvidia-smi &>/dev/null; then
        # Enable persistence mode (keeps GPU initialized)
        sudo -n /usr/bin/nvidia-smi -pm 1 2>/dev/null && log "NVIDIA persistence mode enabled"

        # Set power limit to maximum
        local max_power
        max_power=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$max_power" && "$max_power" -gt 0 ]]; then
            sudo -n /usr/bin/nvidia-smi -pl "$max_power" 2>/dev/null && log "NVIDIA power limit set to ${max_power}W"
        fi

        # Prevent NVIDIA GPU runtime suspend
        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo on > "$nvidia_pci" 2>/dev/null && log "NVIDIA runtime suspend disabled"
                fi
            fi
        done
    fi

    # Set power profile to performance (if power-profiles-daemon is available)
    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set performance 2>/dev/null && log "Power profile set to performance"
    fi
}

restore_balanced_mode() {
    log "Restoring balanced mode..."

    # Restore CPU governor to original
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "${ORIG_GOV:-powersave}" > "$gov" 2>/dev/null
    done

    # AMD pstate: restore energy performance preference
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        if [[ -w "$epp" ]]; then
            echo "${ORIG_EPP:-balance_performance}" > "$epp" 2>/dev/null
        fi
    done

    # Restore kernel tuning to original values
    [[ -n "${ORIG_SPLIT_LOCK:-}" ]] && sudo -n /usr/bin/sysctl -w kernel.split_lock_mitigate="${ORIG_SPLIT_LOCK}" 2>/dev/null
    sudo -n /usr/bin/sysctl -w vm.max_map_count="${ORIG_MAX_MAP:-1048576}" 2>/dev/null
    sudo -n /usr/bin/sysctl -w vm.compaction_proactiveness="${ORIG_COMPACTION:-20}" 2>/dev/null
    sudo -n /usr/bin/sysctl -w kernel.nmi_watchdog="${ORIG_NMI:-1}" 2>/dev/null

    # Restore transparent hugepages
    echo "${ORIG_THP:-always}" | sudo -n /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1

    # NVIDIA dGPU restore
    if command -v nvidia-smi &>/dev/null; then
        # Restore default power limit
        local default_power
        default_power=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$default_power" && "$default_power" -gt 0 ]]; then
            sudo -n /usr/bin/nvidia-smi -pl "$default_power" 2>/dev/null
        fi

        # Re-enable NVIDIA GPU runtime suspend (power saving)
        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo auto > "$nvidia_pci" 2>/dev/null
                fi
            fi
        done

        # Disable persistence mode (allow GPU to sleep)
        sudo -n /usr/bin/nvidia-smi -pm 0 2>/dev/null
    fi

    # Restore power profile to balanced
    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set balanced 2>/dev/null
    fi

    log "Balanced mode restored"
}

CLEANUP_DONE=false
cleanup() {
    if $CLEANUP_DONE; then return; fi
    CLEANUP_DONE=true
    pkill -f steam-library-mount 2>/dev/null || true
    pkill -f gaming-keybind-monitor 2>/dev/null || true
    sudo -n /usr/local/bin/gamescope-nm-stop 2>/dev/null || true
    restore_balanced_mode
    # Unmask sleep targets in case switch-to-desktop wasn't called
    sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
    rm -f /tmp/.gaming-session-active
}
trap cleanup EXIT INT TERM

# Enable performance mode immediately on session start
enable_performance_mode

if /usr/bin/lspci 2>/dev/null | grep -qi nvidia; then
    export GAMESCOPE_BIN="/usr/local/lib/gamescope-nvidia/gamescope"
    log "Using NVIDIA gamescope wrapper with --force-composition"
fi

sudo -n /usr/local/bin/gamescope-nm-start 2>/dev/null || {
    log "Warning: Could not start NetworkManager"
}

if [[ -x /usr/local/bin/steam-library-mount ]]; then
    /usr/local/bin/steam-library-mount &
    log "Steam library drive monitor started"
else
    log "Warning: steam-library-mount not found"
fi

echo "gamescope" > /tmp/.gaming-session-active

keybind_ok=true

if ! python3 -c "import evdev" 2>/dev/null; then
    log "WARNING: python-evdev not installed"
    keybind_ok=false
fi

if ! groups | grep -qw input; then
    log "WARNING: User not in 'input' group"
    keybind_ok=false
fi

if $keybind_ok && ! ls /dev/input/event* >/dev/null 2>&1; then
    log "WARNING: No input devices accessible"
    keybind_ok=false
fi

if $keybind_ok; then
    /usr/local/bin/gaming-keybind-monitor &
    log "Keybind monitor started (Super+Shift+R to exit)"
else
    log "Keybind monitor NOT started"
fi

export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_ENABLE_VOLUME_HANDLER=1

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=$?

exit $rc
NM_WRAPPER

  sudo chmod +x "$nm_wrapper"
  info "Created $nm_wrapper"

  info "Creating SDDM session entry..."
  local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"

  sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode (ChimeraOS)
Comment=Steam Big Picture with ChimeraOS gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
SESSION_DESKTOP

  info "Created $session_desktop"

  info "Creating session-select script..."
  local os_session_select="/usr/lib/os-session-select"

  sudo tee "$os_session_select" > /dev/null << 'OS_SESSION_SELECT'
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || {
  echo "Warning: Failed to update session config"
}
sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n /usr/bin/systemctl restart sddm &>/dev/null &
disown
exit 0
OS_SESSION_SELECT

  sudo chmod +x "$os_session_select"
  info "Created $os_session_select"

  info "Creating switch-to-gaming script..."
  local switch_script="/usr/local/bin/switch-to-gaming"

  sudo tee "$switch_script" > /dev/null << 'SWITCH_SCRIPT'
#!/bin/bash
# Inhibit suspend FIRST - prevents suspend when monitor detaches during switch
sudo -n /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch gaming 2>/dev/null || {
  notify-send -u critical -t 3000 "Gaming Mode" "Failed to update session config" 2>/dev/null || true
}
notify-send -u normal -t 2000 "Gaming Mode" "Switching to Gaming Mode..." 2>/dev/null || true
pkill -9 gamescope 2>/dev/null || true
pkill -9 -f gamescope-session 2>/dev/null || true
sleep 1
sudo -n /usr/bin/chvt 2 2>/dev/null || true
sleep 0.3
sudo -n /usr/bin/systemctl restart sddm
SWITCH_SCRIPT

  sudo chmod +x "$switch_script"
  info "Created $switch_script"

  info "Creating switch-to-desktop script..."
  local switch_desktop_script="/usr/local/bin/switch-to-desktop"

  sudo tee "$switch_desktop_script" > /dev/null << 'SWITCH_DESKTOP'
#!/bin/bash
if [[ ! -f /tmp/.gaming-session-active ]]; then
  exit 0
fi
rm -f /tmp/.gaming-session-active

sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true

# Re-enable Bluetooth
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true

timeout 5 steam -shutdown 2>/dev/null || true
sleep 1

pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true

for _ in {1..6}; do
  pgrep -x gamescope >/dev/null 2>&1 || break
  sleep 0.5
done

if pgrep -x gamescope >/dev/null 2>&1; then
  pkill -9 gamescope 2>/dev/null || true
  pkill -9 -f gamescope-session 2>/dev/null || true
fi

sleep 2

sudo -n /usr/bin/chvt 2 2>/dev/null || true
sleep 0.5
# Use nohup + restart (atomic) so the SDDM restart survives session teardown.
# stop+start fails because SDDM kills the session scope (including this script)
# before start can execute.
nohup sudo -n /usr/bin/systemctl restart sddm &>/dev/null &
disown
exit 0
SWITCH_DESKTOP

  sudo chmod +x "$switch_desktop_script"
  info "Created $switch_desktop_script"

  info "Creating gaming mode keybind monitor..."
  local keybind_monitor="/usr/local/bin/gaming-keybind-monitor"

  sudo tee "$keybind_monitor" > /dev/null << 'KEYBIND_MONITOR'
#!/usr/bin/env python3
import sys
import subprocess
import time
import syslog

def log(msg, error=False):
    print(msg, file=sys.stderr if error else sys.stdout)
    syslog.syslog(syslog.LOG_ERR if error else syslog.LOG_INFO, msg)

syslog.openlog("gaming-keybind-monitor", syslog.LOG_PID)

try:
    import evdev
    from evdev import ecodes
except ImportError:
    log("FATAL: python-evdev not installed", error=True)
    sys.exit(1)

def find_keyboards():
    keyboards = []
    devices_checked = 0
    permission_errors = 0
    for path in evdev.list_devices():
        devices_checked += 1
        try:
            device = evdev.InputDevice(path)
            caps = device.capabilities()
            if ecodes.EV_KEY in caps:
                keys = caps[ecodes.EV_KEY]
                if ecodes.KEY_A in keys and ecodes.KEY_R in keys:
                    keyboards.append(device)
        except PermissionError:
            permission_errors += 1
        except Exception:
            continue
    if permission_errors > 0 and not keyboards:
        log(f"FATAL: Permission denied on {permission_errors}/{devices_checked} input devices.", error=True)
    return keyboards

def monitor_keyboards(keyboards):
    meta_pressed = False
    shift_pressed = False
    from selectors import DefaultSelector, EVENT_READ
    selector = DefaultSelector()
    for kbd in keyboards:
        selector.register(kbd, EVENT_READ)
    log(f"Monitoring {len(keyboards)} keyboard(s) for Super+Shift+R...")
    try:
        while True:
            for key, mask in selector.select():
                device = key.fileobj
                try:
                    for event in device.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA):
                            meta_pressed = event.value > 0
                        elif event.code in (ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT):
                            shift_pressed = event.value > 0
                        elif event.code == ecodes.KEY_R and event.value == 1:
                            if meta_pressed and shift_pressed:
                                log("Super+Shift+R detected! Switching to desktop...")
                                subprocess.run(['/usr/local/bin/switch-to-desktop'])
                                return
                except Exception as e:
                    log(f"Read error: {e}", error=True)
                    continue
    except KeyboardInterrupt:
        pass
    finally:
        selector.close()

def main():
    time.sleep(2)
    keyboards = find_keyboards()
    if not keyboards:
        log("FATAL: No accessible keyboards found!", error=True)
        sys.exit(1)
    monitor_keyboards(keyboards)

if __name__ == '__main__':
    main()
KEYBIND_MONITOR

  sudo chmod +x "$keybind_monitor"
  info "Created $keybind_monitor"

  info "Creating SDDM session switching config..."
  local sddm_gaming_conf="/etc/sddm.conf.d/zz-gaming-session.conf"

  local autologin_user="$current_user"
  if [[ -f /etc/sddm.conf.d/autologin.conf ]]; then
    autologin_user=$(sed -n 's/^User=//p' /etc/sddm.conf.d/autologin.conf 2>/dev/null | head -1)
    [[ -z "$autologin_user" ]] && autologin_user="$current_user"
  fi

  sudo tee "$sddm_gaming_conf" > /dev/null << SDDM_GAMING
[Autologin]
User=${autologin_user}
Session=hyprland-uwsm
Relogin=true
SDDM_GAMING

  info "Created $sddm_gaming_conf"

  info "Creating session switching helper script..."
  local session_helper="/usr/local/bin/gaming-session-switch"

  sudo tee "$session_helper" > /dev/null << 'SESSION_HELPER'
#!/bin/bash
CONF="/etc/sddm.conf.d/zz-gaming-session.conf"
if [[ ! -f "$CONF" ]]; then
  echo "Error: Config file not found: $CONF" >&2
  exit 1
fi

case "$1" in
  gaming)
    sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "$CONF"
    echo "Session set to: gaming mode"
    ;;
  desktop)
    sed -i 's/^Session=.*/Session=hyprland-uwsm/' "$CONF"
    echo "Session set to: desktop mode"
    ;;
  *)
    echo "Usage: $0 {gaming|desktop}" >&2
    exit 1
    ;;
esac
SESSION_HELPER

  sudo chmod +x "$session_helper"
  info "Created $session_helper"

  local sudoers_session="/etc/sudoers.d/gaming-session-switch"

  if [[ -f "$sudoers_session" ]]; then
    info "Removing old sudoers rules to update..."
    sudo rm -f "$sudoers_session"
  fi

  info "Creating sudoers rules for session switching..."

  local switch_output
  switch_output=$(sudo tee "$sudoers_session" << 'SUDOERS_SWITCH' 2>&1
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch *
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start sddm
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt *
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bluetooth.service
%video ALL=(ALL) NOPASSWD: /usr/bin/rfkill unblock bluetooth
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
SUDOERS_SWITCH
)
  local switch_exit=$?

  if [[ $switch_exit -eq 0 ]]; then
    sudo chmod 0440 "$sudoers_session"
    info "Sudoers rules created successfully"
  else
    err "Failed to create sudoers file (exit code: $switch_exit)"
  fi

  info "Adding Hyprland keybind..."
  local hypr_dir="${user_home}/.config/hypr"
  local gaming_conf="${hypr_dir}/gaming-mode.conf"
  local hypr_conf="${hypr_dir}/hyprland.conf"

  # Create a dedicated gaming-mode config file (survives omarchy-refresh-hyprland)
  cat > "$gaming_conf" << 'GAMING_CONF'
# Gaming Mode keybind (managed by Super_Shift_S installer - do not edit)
bindd = SUPER SHIFT, S, Gaming Mode, exec, /usr/local/bin/switch-to-gaming
GAMING_CONF
  info "Created $gaming_conf"

  # Source the gaming config from hyprland.conf if not already sourced
  if [[ -f "$hypr_conf" ]]; then
    if ! grep -q "gaming-mode.conf" "$hypr_conf" 2>/dev/null; then
      echo "" >> "$hypr_conf"
      echo "# Gaming Mode (managed by Super_Shift_S installer)" >> "$hypr_conf"
      echo "source = ~/.config/hypr/gaming-mode.conf" >> "$hypr_conf"
      info "Added gaming-mode.conf source to hyprland.conf"
    else
      info "gaming-mode.conf already sourced in hyprland.conf"
    fi
  else
    warn "hyprland.conf not found - you'll need to add: source = ~/.config/hypr/gaming-mode.conf"
  fi

  # Remove old keybind from bindings.conf if it exists (cleanup from prior installs)
  local hypr_bindings_conf="${hypr_dir}/bindings.conf"
  if [[ -f "$hypr_bindings_conf" ]] && grep -q "switch-to-gaming" "$hypr_bindings_conf" 2>/dev/null; then
    sed -i '/switch-to-gaming/d' "$hypr_bindings_conf"
    sed -i '/^$/N;/^\n$/d' "$hypr_bindings_conf"
    info "Removed old keybind from bindings.conf (now in gaming-mode.conf)"
  fi

  info "Steam compatibility scripts provided by gamescope-session-steam-git"

  info "Setting up Omarchy post-update hook..."
  local hooks_dir="${user_home}/.config/omarchy/hooks"
  local post_update_hook="${hooks_dir}/post-update"
  local gaming_hook_marker="# gaming-mode-hook"

  mkdir -p "$hooks_dir"

  if [[ -f "$post_update_hook" ]]; then
    if ! grep -q "$gaming_hook_marker" "$post_update_hook" 2>/dev/null; then
      cat >> "$post_update_hook" << 'GAMING_HOOK'

# gaming-mode-hook
# Re-add gaming-mode.conf source after omarchy-refresh-hyprland
if [[ -f "$HOME/.config/hypr/gaming-mode.conf" ]] && [[ -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  if ! grep -q "gaming-mode.conf" "$HOME/.config/hypr/hyprland.conf" 2>/dev/null; then
    echo "" >> "$HOME/.config/hypr/hyprland.conf"
    echo "# Gaming Mode (managed by Super_Shift_S installer)" >> "$HOME/.config/hypr/hyprland.conf"
    echo "source = ~/.config/hypr/gaming-mode.conf" >> "$HOME/.config/hypr/hyprland.conf"
  fi
fi
GAMING_HOOK
      info "Added gaming-mode hook to existing post-update"
    else
      info "Gaming-mode post-update hook already present"
    fi
  else
    cat > "$post_update_hook" << 'GAMING_HOOK'
#!/bin/bash
# gaming-mode-hook
# Re-add gaming-mode.conf source after omarchy-refresh-hyprland
if [[ -f "$HOME/.config/hypr/gaming-mode.conf" ]] && [[ -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  if ! grep -q "gaming-mode.conf" "$HOME/.config/hypr/hyprland.conf" 2>/dev/null; then
    echo "" >> "$HOME/.config/hypr/hyprland.conf"
    echo "# Gaming Mode (managed by Super_Shift_S installer)" >> "$HOME/.config/hypr/hyprland.conf"
    echo "source = ~/.config/hypr/gaming-mode.conf" >> "$HOME/.config/hypr/hyprland.conf"
  fi
fi
GAMING_HOOK
    chmod +x "$post_update_hook"
    info "Created post-update hook for gaming-mode keybind persistence"
  fi

  info "Verifying NetworkManager integration..."
  echo ""

  local nm_test_ok=true
  local iwd_was_active=false
  systemctl is-active --quiet iwd.service && iwd_was_active=true

  if ! systemctl is-active --quiet NetworkManager.service; then
    info "Testing NetworkManager startup..."
    if sudo systemctl start NetworkManager.service 2>/dev/null; then
      sleep 2
      if nmcli general status &>/dev/null; then
        info "NetworkManager started successfully"
        if nmcli general status 2>/dev/null | grep -qE "connected|connecting"; then
          info "NetworkManager can see network - Steam network access should work"
        else
          warn "NetworkManager running but shows disconnected"
          warn "This is expected if iwd/systemd-networkd manages your connection"
          info "Steam should still be able to use the network via D-Bus"
        fi
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          info "Restoring iwd WiFi connection..."
          sudo systemctl restart iwd.service 2>/dev/null || true
          sleep 2
        fi
      else
        nm_test_ok=false
        err "NetworkManager started but nmcli not responding"
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          sudo systemctl restart iwd.service 2>/dev/null || true
        fi
      fi
    else
      nm_test_ok=false
      err "Failed to start NetworkManager for testing"
    fi
  else
    info "NetworkManager already running - integration should work"
  fi

  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING CONFIGURED (ChimeraOS)"
  echo "================================================================"
  echo ""
  echo "  Usage:"
  echo "    - Press Super+Shift+S in Hyprland to switch to Gaming Mode"
  echo "    - Press Super+Shift+R in Gaming Mode to return to Hyprland"
  echo "    - (Steam's Power > Exit to Desktop also works as fallback)"
  echo ""
  echo "  ChimeraOS packages installed:"
  echo "    - gamescope-session-git (base session framework)"
  echo "    - gamescope-session-steam-git (Steam session)"
  echo ""
  echo "  Files created/modified:"
  echo "    - ~/.config/environment.d/gamescope-session-plus.conf"
  echo "    - /usr/local/bin/gamescope-session-nm-wrapper"
  echo "    - /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
  echo "    - /usr/lib/os-session-select"
  echo "    - /usr/local/bin/switch-to-gaming"
  echo "    - /usr/local/bin/switch-to-desktop"
  echo "    - /usr/local/bin/gaming-keybind-monitor (Super+Shift+R)"
  echo "    - ~/.config/hypr/gaming-mode.conf (keybind - survives omarchy-refresh)"
  echo ""
  echo "  NetworkManager integration (Steam network access):"
  echo "    - /usr/local/bin/gamescope-nm-start"
  echo "    - /usr/local/bin/gamescope-nm-stop"
  echo "    - /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"
  echo "    - /etc/sudoers.d/gaming-session-switch (NM rules added)"

  if [[ -f /etc/NetworkManager/conf.d/10-iwd-backend.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/10-iwd-backend.conf (iwd backend)"
  fi
  if [[ -f /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf (systemd-networkd coexistence)"
  fi
  echo ""

  if [[ "$nm_test_ok" != "true" ]]; then
    echo "  WARNING: NetworkManager test failed!"
    echo "  Steam may not have network access in Gaming Mode."
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Ensure NetworkManager is installed: pacman -S networkmanager"
    echo "    2. Check if iwd is running: systemctl status iwd"
    echo "    3. Try manually: sudo systemctl start NetworkManager && nmcli general"
    echo "    4. Check logs: journalctl -u NetworkManager -n 50"
    echo ""
  fi

  if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 && info "Hyprland config reloaded" || true
  fi

  return 0
}

verify_installation() {
  echo ""
  echo "================================================================"
  echo "  GAMING MODE INSTALLATION VERIFICATION"
  echo "================================================================"
  echo ""

  local all_ok=true
  local missing_files=()
  local permission_issues=()

  declare -A expected_files=(
    ["/usr/local/bin/gamescope-session-nm-wrapper"]="755:ChimeraOS session with NM wrapper"
    ["/usr/local/lib/gamescope-nvidia/gamescope"]="755:NVIDIA gamescope wrapper (--force-composition)"
    ["/usr/local/bin/gaming-session-switch"]="755:Session switching helper (gaming/desktop)"
    ["/usr/lib/os-session-select"]="755:Steam Exit to Desktop handler"
    ["/usr/local/bin/switch-to-gaming"]="755:Hyprland to Gaming Mode switcher"
    ["/usr/local/bin/switch-to-desktop"]="755:Gaming Mode to Desktop switcher (Super+Shift+R)"
    ["/usr/local/bin/gaming-keybind-monitor"]="755:Keybind monitor for Super+Shift+R"
    ["/usr/local/bin/gamescope-nm-start"]="755:NetworkManager start script"
    ["/usr/local/bin/gamescope-nm-stop"]="755:NetworkManager stop script"
    ["/usr/local/bin/steam-library-mount"]="755:Steam library drive auto-mount script"
    ["/usr/bin/steamos-session-select"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-update"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/jupiter-biosupdate"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-select-branch"]="755:Steam compatibility (from AUR package)"
    ["/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"]="644:SDDM session entry"
    ["/usr/share/gamescope-session-plus/gamescope-session-plus"]="755:ChimeraOS session launcher (from AUR)"
    ["/etc/sddm.conf.d/zz-gaming-session.conf"]="644:SDDM session switching config"
    ["/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"]="644:Polkit NM rules"
    ["/etc/polkit-1/rules.d/50-udisks-gaming.rules"]="644:Polkit udisks2 rules (external drive mount)"
    ["/etc/sudoers.d/gaming-session-switch"]="440:Sudoers rules"
    ["/etc/NetworkManager/conf.d/10-iwd-backend.conf"]="644:NM iwd backend config (optional)"
    ["/etc/NetworkManager/conf.d/20-unmanaged-systemd.conf"]="644:NM systemd coexistence (optional)"
    ["/etc/udev/rules.d/99-gaming-performance.rules"]="644:Udev performance rules"
    ["/etc/sudoers.d/gaming-mode-sysctl"]="440:Performance sudoers"
    ["/etc/security/limits.d/99-gaming-memlock.conf"]="644:Memlock limits"
    ["/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf"]="644:PipeWire low-latency"
    ["/etc/environment.d/99-shader-cache.conf"]="644:Shader cache config"
  )
  echo "  FILE STATUS:"
  echo "  ------------"
  echo ""

  for file in "${!expected_files[@]}"; do
    local expected_perm="${expected_files[$file]%%:*}"
    local description="${expected_files[$file]#*:}"
    local is_optional=false

    [[ "$description" == *"(optional)"* ]] && is_optional=true

    if sudo test -f "$file" 2>/dev/null; then
      local actual_perm
      actual_perm=$(sudo stat -c "%a" "$file" 2>/dev/null)

      if [[ "$actual_perm" == "$expected_perm" ]]; then
        printf "  ✓ %-55s [%s] OK\n" "$file" "$actual_perm"
      else
        printf "  ⚠ %-55s [%s] (expected %s)\n" "$file" "$actual_perm" "$expected_perm"
        permission_issues+=("$file: has $actual_perm, expected $expected_perm")
        all_ok=false
      fi
    else
      if $is_optional; then
        printf "  - %-55s [SKIPPED] %s\n" "$file" "(optional)"
      else
        printf "  ✗ %-55s [MISSING]\n" "$file"
        missing_files+=("$file: $description")
        all_ok=false
      fi
    fi
  done

  echo ""
  echo "  HYPRLAND KEYBIND:"
  echo "  -----------------"
  local gaming_conf="$HOME/.config/hypr/gaming-mode.conf"
  local hypr_main="$HOME/.config/hypr/hyprland.conf"
  if [[ -f "$gaming_conf" ]] && grep -q "switch-to-gaming" "$gaming_conf" 2>/dev/null; then
    echo "  ✓ Gaming Mode keybind (Super+Shift+S) in gaming-mode.conf"
    if [[ -f "$hypr_main" ]] && grep -q "gaming-mode.conf" "$hypr_main" 2>/dev/null; then
      echo "  ✓ gaming-mode.conf sourced in hyprland.conf"
    else
      echo "  ✗ gaming-mode.conf NOT sourced in hyprland.conf"
      all_ok=false
    fi
  else
    echo "  ✗ Gaming Mode keybind NOT found"
    all_ok=false
  fi

  echo ""
  echo "  CHIMERAOS PACKAGES:"
  echo "  -------------------"
  if check_package "gamescope-session-git" || check_package "gamescope-session"; then
    echo "  ✓ gamescope-session installed"
  else
    echo "  ✗ gamescope-session NOT installed"
    all_ok=false
  fi
  if check_package "gamescope-session-steam-git" || check_package "gamescope-session-steam"; then
    echo "  ✓ gamescope-session-steam installed"
  else
    echo "  ✗ gamescope-session-steam NOT installed"
    all_ok=false
  fi

  echo ""
  echo "  STEAM LIBRARY DRIVE SUPPORT:"
  echo "  -----------------------------"
  if [[ -x "/usr/local/bin/steam-library-mount" ]]; then
    echo "  ✓ steam-library-mount script installed"
  else
    echo "  ✗ steam-library-mount NOT found - external Steam libraries will not auto-mount"
    all_ok=false
  fi
  if check_package "udisks2"; then
    echo "  ✓ udisks2 installed (mount backend)"
  else
    echo "  ✗ udisks2 NOT installed"
    all_ok=false
  fi
  if sudo test -f "/etc/polkit-1/rules.d/50-udisks-gaming.rules" 2>/dev/null; then
    echo "  ✓ udisks2 polkit rules configured"
  else
    echo "  ✗ udisks2 polkit rules NOT found"
    all_ok=false
  fi

  echo ""
  echo "  KEYBIND MONITOR (Super+Shift+R):"
  echo "  ---------------------------------"
  local keybind_ok=true

  if check_package "python-evdev"; then
    echo "  ✓ python-evdev installed"
  else
    echo "  ✗ python-evdev NOT installed"
    keybind_ok=false
    all_ok=false
  fi

  if python3 -c "import evdev" 2>/dev/null; then
    echo "  ✓ python-evdev importable"
  else
    echo "  ✗ python-evdev cannot be imported"
    keybind_ok=false
    all_ok=false
  fi

  if groups 2>/dev/null | grep -qw input; then
    echo "  ✓ User in 'input' group"
  else
    echo "  ✗ User NOT in 'input' group (required for keybind)"
    keybind_ok=false
    all_ok=false
  fi

  if ls /dev/input/event* >/dev/null 2>&1; then
    local test_device=$(ls /dev/input/event* 2>/dev/null | head -1)
    if [[ -r "$test_device" ]]; then
      echo "  ✓ Can read input devices"
    else
      echo "  ✗ Cannot read $test_device (permission denied)"
      echo "    (May need to log out/in after adding to input group)"
      keybind_ok=false
      all_ok=false
    fi
  else
    echo "  ⚠ No /dev/input/event* devices found"
  fi

  if $keybind_ok; then
    echo "  → Super+Shift+R keybind should work"
  else
    echo "  → Super+Shift+R keybind will NOT work (use Steam > Power > Exit to Desktop)"
  fi

  echo ""
  echo "  USER CONFIG:"
  echo "  ------------"
  local user_conf="$HOME/.config/environment.d/gamescope-session-plus.conf"
  if [[ -f "$user_conf" ]]; then
    echo "  ✓ gamescope-session-plus.conf exists"
  else
    echo "  ✗ gamescope-session-plus.conf NOT found"
    all_ok=false
  fi

  echo ""
  echo "  USER GROUPS:"
  echo "  ------------"
  local user_groups
  user_groups=$(groups 2>/dev/null)
  for grp in video input wheel; do
    if echo "$user_groups" | grep -qw "$grp"; then
      printf "  ✓ User is in '%s' group\n" "$grp"
    else
      printf "  ✗ User is NOT in '%s' group\n" "$grp"
      all_ok=false
    fi
  done

  echo ""
  echo "  SERVICE STATUS:"
  echo "  ---------------"
  echo "  NetworkManager: $(systemctl is-active NetworkManager.service 2>/dev/null || echo 'inactive') (should be inactive until gaming mode)"
  echo "  iwd:            $(systemctl is-active iwd.service 2>/dev/null || echo 'inactive')"
  echo "  systemd-networkd: $(systemctl is-active systemd-networkd.service 2>/dev/null || echo 'inactive')"
  echo "  polkit:         $(systemctl is-active polkit.service 2>/dev/null || echo 'inactive')"

  echo ""
  echo "  SUDO PERMISSIONS TEST:"
  echo "  ----------------------"
  if sudo -n true 2>/dev/null; then
    echo "  ✓ sudo -n works (passwordless sudo available)"
    if sudo -n -l /usr/local/bin/gamescope-nm-start &>/dev/null; then
      echo "  ✓ Can run gamescope-nm-start without password"
    else
      echo "  ✗ Cannot run gamescope-nm-start without password"
      all_ok=false
    fi
  else
    echo "  ⚠ sudo -n test skipped (requires recent sudo auth)"
    echo "    Run: sudo -v && sudo -n -l /usr/local/bin/gamescope-nm-start"
  fi

  echo ""
  echo "================================================================"
  if $all_ok; then
    echo "  ✓ ALL CHECKS PASSED - Gaming Mode should work correctly"
  else
    echo "  ⚠ SOME ISSUES DETECTED"
    echo ""
    if ((${#missing_files[@]})); then
      echo "  Missing files (${#missing_files[@]}):"
      for f in "${missing_files[@]}"; do
        echo "    - $f"
      done
    fi
    if ((${#permission_issues[@]})); then
      echo ""
      echo "  Permission issues (${#permission_issues[@]}):"
      for p in "${permission_issues[@]}"; do
        echo "    - $p"
      done
    fi
    echo ""
    echo "  Re-run the installer to fix these issues."
  fi
  echo "================================================================"
  echo ""

  $all_ok && return 0 || return 1
}

execute_setup() {
  sudo -k
  sudo -v || die "sudo authentication required"

  validate_environment

  echo ""
  echo "================================================================"
  echo "  SUPER SHIFT S GAMING MODE INSTALLER v${Super_Shift_S_VERSION}"
  echo "  Dependencies & GPU Configuration"
  echo "================================================================"
  echo ""

  check_steam_dependencies
  bootstrap_steam
  check_nvidia_kernel_params
  install_nvidia_deckmode_env
  setup_requirements
  setup_session_switching

  if [ "$NEEDS_REBOOT" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: REBOOT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  Bootloader configuration has been updated (nvidia-drm.modeset=1)."
    echo "  You MUST reboot for the kernel parameter to take effect."
    echo ""
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      echo "  Additionally, user groups were updated (video/input/wheel)."
    fi
    echo ""
    read -p "Reboot now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Rebooting..."
      sleep 2
      systemctl reboot
    else
      echo ""
      echo "  Remember to reboot before continuing!"
      echo ""
    fi
  elif [ "$NEEDS_RELOGIN" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: LOG OUT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  User groups have been updated. You MUST log out and log back in"
    echo "  for the changes to take effect."
    echo ""
    read -r -p "Press Enter to exit (remember to log out)..."
  else
    echo ""
    echo "================================================================"
    echo "  SETUP COMPLETE"
    echo "================================================================"
    echo ""
    echo "  Dependencies, GPU configuration, and session switching are ready."
    echo ""
    echo "  To switch to Gaming Mode: Press Super+Shift+S"
    echo "  To return to Desktop:     Press Super+Shift+R"
    echo ""
  fi

  echo ""
  read -p "Run installation verification? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    verify_installation
  fi
}

show_help() {
  echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --help, -h      Show this help message"
  echo "  --verify, -v    Run verification only (check all files and permissions)"
  echo "  --version       Show version number"
  echo ""
  echo "Without options, runs the full installation/setup process."
  echo ""
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --verify|-v)
    echo "Running verification only..."
    verify_installation
    exit $?
    ;;
  --version)
    echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
    exit 0
    ;;
  "")
    execute_setup
    ;;
  *)
    echo "Unknown option: $1"
    echo "Use --help for usage information."
    exit 1
    ;;
esac
