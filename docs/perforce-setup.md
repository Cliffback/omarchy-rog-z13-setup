# Perforce Setup on Linux

Guide for configuring the Perforce CLI and P4V on this workstation.

## Required Configuration Files

### `~/.p4enviro`

Set `P4IGNORE` here so both the CLI and P4V pick it up:

```bash
P4IGNORE=.p4ignore.txt
```

> **Note:** On Linux, P4V launched from the GUI/desktop menu does not reliably inherit `P4IGNORE` from workspace `.p4config`. `~/.p4enviro` is the reliable source.

### `~/.p4config` (or workspace `.p4config`)

```ini
P4PORT=ssl:your-server:1666
P4USER=your-username
P4CLIENT=your-workspace-name
```

> Do **not** store passwords in `.p4config`. Use `p4 login` instead.

### Shell environment

Add this once to `~/.bashrc` or `~/.zshrc` so `p4` knows to look for local config files:

```bash
export P4CONFIG=.p4config
```

Then reload:

```bash
source ~/.bashrc
```

## Authentication

```bash
p4 login
```

This stores a time-limited ticket in `~/.p4tickets`.

- Logout: `p4 logout`
- Check current settings: `p4 set`
- List your workspaces: `p4 clients -u $P4USER`

## P4IGNORE / `.p4ignore.txt`

Projects should include a `.p4ignore.txt` in the workspace root. Verify a file is ignored:

```bash
p4 ignores -i <file_path>
```

No output means the file is ignored.

## Reverting Files

Remove a file from a changelist without deleting the local copy:

```bash
p4 revert -k <file_path>
```

Preview before reverting:

```bash
p4 revert -k -n <file_path>
```

## Troubleshooting

### `File .../.p4config is protected by 'P4_SYSTEMIGNORE'`

This warning appears when the Perforce server admin has configured a system-level ignore rule that protects certain local config values. If you have duplicated the needed settings (like `P4IGNORE`) into `~/.p4enviro`, functionality is unaffected and the warning can be safely ignored.

### `.p4config` not picked up?

Make sure `P4CONFIG=.p4config` is exported in your shell, and you're running `p4` from the same directory (or a child directory) where `.p4config` lives.
