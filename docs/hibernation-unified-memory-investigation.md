# Hibernation on Unified Memory Systems - Investigation & Plan

**Date:** 2026-03-09  
**System:** ASUS ROG Flow Z13 (2025) with unified memory (CPU+GPU shared RAM)  
**Issue:** Hibernate option missing from Omarchy menu despite `omarchy-hibernation-setup` reporting "already set up"

## Problem Summary

The user has 121GB total RAM with ~64GB allocated to GPU (unified memory architecture). The Omarchy menu does not show the Hibernate option, but running `omarchy-hibernation-setup` says hibernation is already configured.

## Root Cause Analysis

### The Check That Hides Hibernate

The `omarchy-menu` script calls `omarchy-hibernation-available` before showing the Hibernate option:

```bash
# From show_system_menu() in omarchy-menu
omarchy-hibernation-available && options="$options\n󰤁  Hibernate"
```

### What `omarchy-hibernation-available` Checks

```bash
#!/bin/bash
# Check if hibernation is supported
if [[ ! -f /sys/power/image_size ]]; then
  exit 1
fi

# Sum all swap sizes (excluding zram)
SWAPSIZE_KB=$(awk '!/Filename|zram/ {sum += $3} END {print sum+0}' /proc/swaps)
SWAPSIZE=$(( 1024 * ${SWAPSIZE_KB:-0} ))

HIBERNATION_IMAGE_SIZE=$(cat /sys/power/image_size)

if (( SWAPSIZE > HIBERNATION_IMAGE_SIZE )) && [[ -f /etc/mkinitcpio.conf.d/omarchy_resume.conf ]]; then
  exit 0
else
  exit 1
fi
```

### Current System State

| Component | Value | Notes |
|-----------|-------|-------|
| `/sys/power/image_size` | 52,157,538,304 bytes (~48.6 GB) | Kernel's target hibernation image size |
| MemTotal | 127,396,660 KB (~121 GB) | Total system RAM |
| Swap file size | 28,356,008 KB (~27 GB) | `/swap/swapfile` |
| zram size | 14,178,300 KB (~13.5 GB) | Excluded from hibernation |
| Resume hook | Present | `/etc/mkinitcpio.conf.d/omarchy_resume.conf` contains `HOOKS+=(resume)` |

### Why It Fails

The check `SWAPSIZE > HIBERNATION_IMAGE_SIZE` fails:
- Swap: ~29 GB (29,036,552,192 bytes)
- Image size: ~48.6 GB (52,157,538,304 bytes)
- **29 GB < 48.6 GB → FAIL**

### Why Setup Says "Already Configured"

The `omarchy-hibernation-setup` script only checks if the resume hook exists:

```bash
if [[ -f $MKINITCPIO_CONF ]] && grep -q "^HOOKS+=(resume)$" "$MKINITCPIO_CONF"; then
  echo "Hibernation is already set up"
  exit 0
fi
```

It does NOT verify that swap is large enough. This is the bug.

## Technical Context

### `/sys/power/image_size` Explained

From kernel documentation:
- Default value: ~40% of MemTotal (2/5 of RAM)
- Purpose: Target size the kernel tries to compress hibernation image into
- **It's writable!** Can be changed dynamically: `echo N > /sys/power/image_size`
- If actual memory usage exceeds what can be compressed into this size, hibernation fails

### Unified Memory Consideration

On systems with unified memory (CPU + GPU sharing RAM):
- MemTotal includes GPU-allocated memory
- GPU allocation can change dynamically (user reported 64GB currently allocated to GPU)
- Actual CPU-side memory needing hibernation may be much less than MemTotal
- The 40% default for `image_size` may be overly conservative

## Solution Options

### Option A: Reduce `image_size` (Quick Fix, No Disk Changes)

Set `image_size` to be smaller than swap:

```bash
# Set to 25GB (less than 27GB swap)
echo 25000000000 | sudo tee /sys/power/image_size

# Make persistent via systemd tmpfiles or boot script
```

**Pros:**
- No disk space needed
- Works immediately

**Cons:**
- Hibernation may fail if RAM usage exceeds what can compress to 25GB
- Need to persist across reboots

### Option B: Resize Swap File (Robust Fix)

```bash
# 1. Disable current swap
sudo swapoff /swap/swapfile

# 2. Remove old swap file
sudo rm /swap/swapfile

# 3. Create larger swap file (e.g., 64GB)
sudo btrfs filesystem mkswapfile -s 64G /swap/swapfile

# 4. Enable new swap
sudo swapon -p 0 /swap/swapfile

# 5. Update resume_offset in boot config (may have changed)
RESUME_OFFSET=$(sudo btrfs inspect-internal map-swapfile -r /swap/swapfile)
# Update /etc/limine-entry-tool.d/resume.conf with new offset

# 6. Regenerate initramfs and boot entry
sudo limine-mkinitcpio
sudo limine-update
```

**Pros:**
- Works reliably for all memory usage scenarios
- One-time fix

**Cons:**
- Requires 64GB+ disk space
- Must update `resume_offset` in boot config
- Need to regenerate initramfs

### Option C: Improve Omarchy Scripts (Upstream Fix)

Propose changes to Omarchy to handle this better:

1. **`omarchy-hibernation-setup`**: Add swap size validation
2. **`omarchy-hibernation-available`**: Consider tuning `image_size` dynamically
3. **Add unified memory detection**: Adjust defaults for unified memory systems

## Recommended Plan

### Phase 1: Fix Current System (User Action Required)

Choose Option A or B based on disk space and preference.

**Recommended: Option B with 64GB swap** - matches GPU allocation, provides buffer.

### Phase 2: Add Hibernation Support to This Install Script

Add a new phase to `install.sh` that:
1. Checks if system has unified memory
2. Validates existing swap size vs `image_size`
3. Offers to resize swap if undersized
4. Configures `image_size` appropriately for unified memory systems

### Phase 3: Upstream Improvements (Optional)

File issues or PRs against Omarchy to:
1. Make `omarchy-hibernation-setup` validate swap size
2. Support `--resize-swap` flag to fix undersized swap
3. Add unified memory awareness

## Commands for Debugging

```bash
# Check if hibernation is available
omarchy-hibernation-available && echo "AVAILABLE" || echo "NOT AVAILABLE"

# View current values
cat /sys/power/image_size
cat /proc/swaps
cat /etc/mkinitcpio.conf.d/omarchy_resume.conf
cat /etc/limine-entry-tool.d/resume.conf

# Calculate sizes in GB
python3 -c "
import subprocess
image_size = int(open('/sys/power/image_size').read())
swap_kb = int(subprocess.run(['awk', '!/Filename|zram/ {sum += \$3} END {print sum+0}', '/proc/swaps'], 
              capture_output=True, text=True).stdout)
swap_bytes = swap_kb * 1024
print(f'image_size: {image_size / 1024**3:.1f} GB')
print(f'swap size:  {swap_bytes / 1024**3:.1f} GB')
print(f'Hibernation possible: {swap_bytes > image_size}')
"

# Check unified memory (GPU VRAM from system RAM)
cat /sys/bus/pci/devices/*/mem_info_vram_total 2>/dev/null
```

## Files Involved

| File | Purpose |
|------|---------|
| `/sys/power/image_size` | Kernel's hibernation image target size (writable) |
| `/proc/swaps` | Active swap devices/files |
| `/swap/swapfile` | Btrfs swap file for hibernation |
| `/etc/fstab` | Swap file mount entry |
| `/etc/mkinitcpio.conf.d/omarchy_resume.conf` | Resume hook for initramfs |
| `/etc/limine-entry-tool.d/resume.conf` | Kernel cmdline: `resume=` and `resume_offset=` |
| `$(which omarchy-hibernation-available)` | Script that gates hibernate menu option |
| `$(which omarchy-hibernation-setup)` | Script that configures hibernation |
| `$(which omarchy-menu)` | Main Omarchy menu (calls hibernation-available) |

## References

- [Kernel swap suspend documentation](https://www.kernel.org/doc/html/latest/power/swsusp.html)
- Omarchy source: `~/.local/share/omarchy/bin/omarchy-hibernation-*`
