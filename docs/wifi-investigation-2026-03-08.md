# WiFi Investigation Session - 2026-03-08

## Goal

Investigate why `omarchy update` breaks WiFi on ASUS ROG Flow Z13 (2025) with MediaTek MT7925 WiFi 7 chip, and implement fixes in the `omarchy-rog-z13-setup` repository to prevent future occurrences.

## Instructions

- User runs custom post-install setup script (`install.sh`) after installing Omarchy Linux on ROG Z13
- The script has multiple phases that configure hardware-specific settings
- User wants diagnosis-only approach (no kernel pinning), plus fixes added to the setup script
- `sudo limine-mkinitcpio` is the correct way to rebuild UKI (not plain `mkinitcpio -P`)
- Don't worry about updating the diagnostic script further

## Root Cause Confirmed: Orphan Package Cleanup Removed Firmware

The `omarchy-update-orphan-pkgs` script runs `pacman -Qtdq` to find "orphan" packages (installed as dependencies but nothing requires them) and removes them.

### What happened during update

1. `linux-firmware-amdgpu` and `linux-firmware-mediatek` were installed as dependencies
2. After update, pacman considered them "orphans" 
3. Orphan cleanup removed them: `removing linux-firmware-amdgpu...`
4. UKI was rebuilt AFTER firmware removal → `==> WARNING: Possibly missing firmware for module: 'amdgpu'`
5. On reboot, mt7925e driver couldn't load firmware → WiFi completely unavailable

### Solution

Mark firmware packages as "explicitly installed" using `pacman -D --asexplicit` so they're never considered orphans.

## Secondary Factor

Kernel 6.18 → 6.19 jump may also have MT7925 driver regressions (multiple open bugs in kernel.org bugzilla).

## Device Info

- **WiFi Chip:** MediaTek MT7925 802.11be (WiFi 7) PCIe at `c2:00.0`
- **Working kernel:** `6.18.9-3-cachyos`
- **Broken kernel:** `6.19.6-2-cachyos`
- **Modprobe fix:** `options mt7925e disable_aspm=1`

## Accomplished

### Completed

1. **Created `diagnose-wifi.sh`** - Standalone WiFi diagnostic tool with:
   - 8 diagnostic checks (PCIe, module, kernel messages, firmware files, modprobe config, kernel version, interface status, WiFi service)
   - Interactive fixes (reload module, restart iwd, unblock rfkill, create modprobe config, regenerate initramfs)
   - Log export option

2. **Added `is_pkg_explicit()` to `lib/common.sh`** - Helper function to check if package is explicitly installed

3. **Updated `lib/phase3_hardware.sh`**:
   - Expanded firmware list to 4 packages: `linux-firmware-amdgpu`, `linux-firmware-mediatek`, `linux-firmware-intel`, `linux-firmware-whence`
   - `phase3_check()` now verifies packages are both installed AND explicit
   - `phase3_run()` installs missing firmware, then marks ALL as explicit with `pacman -D --asexplicit`

4. **Created/Updated `docs/wifi-investigation-2026-03-08.md`** - Full context document with:
   - Confirmed root cause (orphan cleanup)
   - Evidence from update logs
   - Details of implemented fixes
   - Recovery steps and useful commands

### Verified

- All scripts pass syntax check (`bash -n`)
- `./install.sh --dry-run` shows all phases pass

## Git Status (as of session end)

```
On branch main
Your branch is ahead of 'origin/main' by 1 commit.

Changes not staged for commit:
    modified:   lib/common.sh
    modified:   lib/phase3_hardware.sh

Untracked files:
    diagnose-wifi.sh
    docs/
```

Changes left uncommitted for manual review.

## Relevant Files

```
/home/cliffback/code/omarchy-rog-z13-setup/
├── diagnose-wifi.sh              # CREATED - WiFi diagnostic tool
├── docs/
│   └── wifi-investigation-2026-03-08.md  # CREATED - This file
├── lib/
│   ├── common.sh                 # MODIFIED - Added is_pkg_explicit()
│   ├── phase0_update.sh          # READ - System update phase
│   ├── phase1_kernel.sh          # READ - Kernel/driver install phase
│   ├── phase2_asusd.sh           # READ - ASUS daemon setup
│   ├── phase3_hardware.sh        # MODIFIED - Firmware install + explicit marking
│   ├── phase4_hyprland.sh        # (exists, not modified)
│   └── phase5_rogquick.sh        # (exists, not modified)
├── install.sh                    # READ - Main installer
├── CLAUDE.md                     # (exists)
└── README.md                     # (exists)
```

## Useful Commands

### Recovery (if WiFi breaks again)

```bash
# Reinstall firmware
sudo pacman -S linux-firmware-mediatek linux-firmware-amdgpu linux-firmware-intel linux-firmware-whence

# Mark as explicit to prevent orphan cleanup
sudo pacman -D --asexplicit linux-firmware-mediatek linux-firmware-amdgpu linux-firmware-intel linux-firmware-whence

# Rebuild UKI
sudo limine-mkinitcpio

# Reboot
sudo reboot
```

### Diagnostics

```bash
# Run diagnostic script
./diagnose-wifi.sh

# Manual checks
lspci -k | grep -A3 MT7925      # Check PCIe device
lsmod | grep mt7925             # Check module loaded
dmesg | grep -i mt7925          # Check kernel messages
iwctl station list              # Check WiFi interface
```

### Check package status

```bash
# Check if package is explicit vs dependency
pacman -Qi linux-firmware-mediatek | grep "Install Reason"

# List all orphan packages (what would be removed)
pacman -Qtdq
```
