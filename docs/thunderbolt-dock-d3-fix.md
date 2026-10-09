# Thunderbolt Dock D3 Sleep Fix

## Date

2026-03-30

## Problem

When using a Thunderbolt dock (CalDigit TS3 Plus) with the ASUS ROG Flow Z13 (2025), the dock's USB hub fails to enumerate. This means no USB devices on the dock are visible to the system — including the built-in Ethernet adapter. The system falls back to Wi-Fi even when a wired connection is available through the dock.

### Symptoms

- `ip link` shows no `enp*` or `eth*` interface (only `lo`, `wlan0`, and docker interfaces)
- `lsusb -t` shows the Thunderbolt USB buses (Bus 005-008) are completely empty — no downstream devices
- `boltctl list` shows the dock as "authorized" and connected at full speed (40 Gb/s)
- `dmesg` shows ACPI errors on the Thunderbolt controller:

```
ACPI Error: Aborting method \M402 due to previous error (AE_AML_LOOP_TIMEOUT)
ACPI Error: Aborting method \_SB.PCI0.GPPC.NHI0.PPS3 due to previous error (AE_AML_LOOP_TIMEOUT)
ACPI Error: Aborting method \_SB.PCI0.GPPC.NHI0._PS3 due to previous error (AE_AML_LOOP_TIMEOUT)
```

A reboot temporarily resolves the issue because the Thunderbolt controller starts fresh in D0 (fully powered state).

## Root Cause

The Z13's UEFI firmware has a buggy ACPI `_PS3` method for the Thunderbolt Native Host Interface (NHI0). `_PS3` is the ACPI method the kernel calls to transition a PCI device into the D3 power state (deepest sleep / effectively off).

PCI power states:

| State | Description |
|-------|-------------|
| D0 | Fully on, fully operational |
| D1/D2 | Intermediate low-power states |
| D3 | Deepest sleep — device is essentially shut down |

Linux's runtime power management (`power/control = auto`) automatically puts idle PCI devices into D3 to save battery. When the Thunderbolt controller is put into D3, the firmware's `_PS3` method enters an infinite loop and times out (`AE_AML_LOOP_TIMEOUT`). This leaves the controller in a broken state where it cannot maintain the PCIe tunnel to the dock, so the dock's internal USB hub never enumerates.

The issue is more likely to occur on battery, because the kernel is more aggressive about entering D3 when power-saving is prioritized.

## Hardware Details

- **Laptop**: ASUS ROG Flow Z13 (2025) — GZ302EA
- **Thunderbolt controller**: Intel JHL6540 Alpine Ridge 4C (PCI vendor `0x8086`, device `0x15d3`)
- **Dock tested**: CalDigit TS3 Plus (Thunderbolt 3)
- **Dock Ethernet chipset**: Intel I210 Gigabit Network Connection (PCI `8086:1533`, kernel driver: `igb`)

## Diagnostic Commands

```bash
# Check if Ethernet interface exists
ip link

# Check if dock USB devices are enumerating
lsusb -t

# Check Thunderbolt authorization status
boltctl list

# Check for ACPI errors (requires sudo)
sudo dmesg | grep -iE 'ACPI Error.*NHI|_PS3|AML_LOOP'

# Check current Thunderbolt controller power management setting
# (the Z13's Alpine Ridge bridges are 0000:61:00.0 and 0000:62:03.0)
cat /sys/bus/pci/devices/0000:61:00.0/power/control
# "auto" = kernel manages sleep (problematic), "on" = always active (fix)

# Check the igb module is loaded (needed for the dock's I210 Ethernet)
lsmod | grep igb
```

## Fix

Two udev rules deployed to `/etc/udev/rules.d/99-thunderbolt-no-d3.rules` (see `templates/99-thunderbolt-no-d3.rules`):

**Rule 1: Prevent D3 sleep on boot and idle**

```
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x15d3", ATTR{power/control}="on"
```

Sets `power/control` to `on` for the Intel Alpine Ridge PCI devices when they are added, preventing the kernel from ever attempting the D3 transition. This handles the boot case and normal runtime idle.

**Rule 2: PCI rescan on dock replug**

```
ACTION=="add", SUBSYSTEM=="thunderbolt", RUN+="/bin/sh -c 'echo 1 > /sys/bus/pci/rescan'"
```

When a dock is unplugged, the buggy ACPI `_PS3` fires during PCI topology teardown, and the entire PCI bridge hierarchy (buses 02-07) is released and fails to re-enumerate on replug. The Thunderbolt subsystem detects the dock reconnection, but the PCI devices never come back. This rule triggers a PCI bus rescan whenever a Thunderbolt device is connected, which forces the kernel to re-enumerate the bridges. Once re-added, Rule 1 fires and sets `power/control` to `on` on the new devices.

Both rules are applied by Phase 10 of the installer.

After creating the rules, reload and trigger:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=pci --attr-match=vendor=0x8086 --attr-match=device=0x15d3
```

## Trade-offs

- The Thunderbolt controller will draw a small amount of extra power when idle (estimated hundreds of milliwatts)
- This only matters on battery without the dock plugged in — when docked, the controller needs to be active anyway
- Much more targeted than the kernel parameter `pcie_port_pm=off`, which would affect every PCIe port on the system

## Alternatives Considered

1. **Kernel parameter `pcie_port_pm=off`** — too broad, disables power management for all PCIe ports
2. **Rebooting when it happens** — unreliable workaround, not a real fix
3. **BIOS/firmware update** — may eventually fix the ACPI method, but not available as of 2026-03-30
