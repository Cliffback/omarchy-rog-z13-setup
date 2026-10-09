# Synology NAS Mounts

Guide for the persistent Synology NAS mounts on this workstation, integrated with Nautilus.

## Overview

The Synology NAS at `192.168.1.155` is mounted via CIFS (SMB) using `/etc/fstab` entries with **systemd automount**. Shares mount automatically on first access and unmount after 60 seconds of idle time. Nautilus integration is done with plain GTK bookmarks pointing at the mount points.

## Mounted Shares

| Share on NAS                      | Mount point           | Nautilus bookmark   |
| --------------------------------- | --------------------- | ------------------- |
| `//192.168.1.155/miniatyrbutikken` | `/mnt/miniatyrbutikken` | `miniatyrbutikken`  |
| `//192.168.1.155/home/Drive`       | `/mnt/drive`            | `drive`             |
| `//192.168.1.155/coruscant`        | `/mnt/coruscant`        | `coruscant`         |

## How It Works

### `/etc/fstab` entries

Each share uses this pattern:

```fstab
//192.168.1.155/<share> /mnt/<name> cifs credentials=/etc/smbcredentials,uid=1000,gid=1000,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10 0 0
```

Key options:

- `credentials=/etc/smbcredentials` — SMB username/password file (see below)
- `uid=1000,gid=1000` — files appear owned by the local user
- `noauto` — don't mount at boot
- `x-systemd.automount` — mount on demand when the path is accessed
- `x-systemd.idle-timeout=60` — unmount after 60s idle
- `x-systemd.mount-timeout=10` — fail fast if the NAS is unreachable (e.g. off the LAN)

### Credentials: `/etc/smbcredentials`

Root-only file (`chmod 600`, owner `root:root`) containing the SMB credentials:

```ini
username=mathias
password=<password>
```

All shares share this single credentials file.

### Nautilus bookmarks: `~/.config/gtk-3.0/bookmarks`

```text
file:///mnt/miniatyrbutikken miniatyrbutikken
file:///mnt/drive drive
file:///mnt/coruscant coruscant
```

These make the mounts appear in the Nautilus sidebar. Clicking one triggers the automount.

## Adding Another Share

1. Create the mount point:

   ```bash
   sudo mkdir /mnt/<name>
   ```

2. Append the fstab entry (same options as above):

   ```bash
   sudo sh -c 'echo "//192.168.1.155/<share> /mnt/<name> cifs credentials=/etc/smbcredentials,uid=1000,gid=1000,noauto,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10 0 0" >> /etc/fstab'
   ```

3. Reload systemd **and start the new automount unit**:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start mnt-<name>.automount
   ```

   > **Note:** The unit name is derived from the mount point path, e.g. `/mnt/coruscant` → `mnt-coruscant.automount`.

4. Add the Nautilus bookmark:

   ```bash
   echo "file:///mnt/<name> <name>" >> ~/.config/gtk-3.0/bookmarks
   ```

5. Verify — this should list the share contents and show a `cifs` mount:

   ```bash
   ls /mnt/<name>
   mount | grep <name>
   ```

## Troubleshooting

### New fstab automount is inactive until started manually

`systemctl daemon-reload` *generates* the `mnt-<name>.automount` unit from fstab but does not start it. Entries added at boot are started automatically via `local-fs.target`; entries added at runtime need an explicit `systemctl start mnt-<name>.automount` (one time only — after a reboot it starts on its own). Until started, the mount point is just an empty directory and `mount` shows nothing.

### Ad-hoc gvfs mounts are not persistent

Opening a share via Nautilus "Other Locations" (`smb://...`) creates a gvfs mount that disappears on logout/reboot and shows up as a separate entry from the bookmarked one. Check with:

```bash
gio mount -l
```

Remove it before relying on the fstab mount:

```bash
gio mount -u "smb://192.168.1.155/<share>/"
```

### `gio mount -u` fails with "File system is busy"

Something has the share open — usually a Nautilus window browsing it. Close the window and retry.
