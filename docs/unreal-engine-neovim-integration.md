# Unreal Engine + Neovim Integration on Omarchy Linux

This document describes the complete bidirectional integration between Unreal Engine 5 and Neovim on Omarchy (Hyprland/Wayland), including all findings, workarounds, and implementation details.

## Overview

The integration enables:
- **UE → nvim**: Double-click a C++ class in the Unreal Editor → it opens in your running nvim instance
- **nvim → UE**: Run `:UnrealEngine open` from nvim → launches the UE editor for the current project
- **Auto-respawn**: If nvim is closed, clicking a C++ class in UE automatically spawns a new nvim instance
- **No freezes**: Dead sockets never block UE thanks to `timeout 3` and a smart wrapper script

## Architecture

```
┌─────────────┐     double-click C++      ┌──────────────────┐
│  Unreal     │ ────────────────────────> │  nvim wrapper    │
│  Editor     │    nvim --server SOCK     │  (intercept)     │
│             │       --remote FILE       └──────────────────┘
│             │                                    │
│             │                                    ▼
│             │                          ┌──────────────────┐
│             │                          │  timeout 3 check │
│             │                          │  (socket alive?) │
│             │                          └──────────────────┘
│             │                                    │
│             │                         dead ──> spawn new nvim
│             │                         alive ─> remote-send
│             │                                    │
│             │                          ┌──────────────────┐
│             │                          │  setsid +          │
│             │                          │  xdg-terminal-exec │
│             │                          └──────────────────┘
│             │                                    │
│             │                          ┌──────────────────┐
│             │ <────────────────────────│  nvim --listen   │
│             │    file opens in buffer  │  SOCK PROJECT    │
└─────────────┘                          └──────────────────┘
```

## Components

### 1. Official Plugin: `mbwilding/UnrealEngine.nvim`

We use the official [`mbwilding/UnrealEngine.nvim`](https://github.com/mbwilding/UnrealEngine.nvim) plugin (not a custom fork). It provides:
- `:UnrealEngine open|build|rebuild|lsp|clean` commands
- Automatic `compile_commands.json` generation for clangd LSP
- Project detection and engine path resolution

The plugin is built from source and installed into the engine's plugin directory:
```
~/UnrealEngine/5.5.4/Engine/Plugins/Developer/NeovimSourceCodeAccess/
```

### 2. nvim Wrapper Script

**Location**: `~/UnrealEngine/bin/wrappers/nvim`

This is the critical piece. UE calls `nvim` to open files, but since `nvim` might not be running (or might have been closed), we intercept the call.

**What it does:**
1. Detects if the call is `--remote` from UE
2. Tests the socket with `timeout 3 nvim --server SOCK --remote-send` — prevents UE from hanging on dead sockets
3. If socket is alive → forwards to real nvim
4. If socket is dead → spawns a new nvim instance on the same socket path

**Key implementation details:**

```bash
# Dead socket detection
timeout 3 "$REAL_NVIM" --server "$SERVER_SOCKET" --remote-send "<Esc>" 2>/dev/null
if [ $? -eq 0 ]; then
    # Socket alive, forward command
    exec "$REAL_NVIM" "$@"
fi

# Spawn new nvim detached from UE's process tree
setsid bash -c "
    xdg-terminal-exec nvim --listen '$SERVER_SOCKET' '$PROJECT_DIR'
" &
```

### 3. Launcher: `ue-5.5.4`

**Location**: `~/UnrealEngine/bin/ue-5.5.4`

The launcher prepends the wrapper directory to PATH before starting UE:
```bash
WRAPPER_DIR="${HOME}/UnrealEngine/bin/wrappers"
export PATH="${WRAPPER_DIR}:${PATH}"
```

This ensures UE's `ExecProcess()` call to `nvim` resolves to our wrapper, not the system nvim.

### 4. Neovim Config: `lua/plugins/ue.lua`

**Location**: `~/.config/nvim/lua/plugins/ue.lua`

Key sections:

**Environment variables passed to UE:**
```lua
vim.env.SDL_VIDEODRIVER = "x11"           -- Force X11 on Wayland
vim.env.GDK_SCALE = "1"
vim.env.QT_SCALE_FACTOR = "1"

-- NVIM env: UE plugin reads this to know which socket to use
vim.env.NVIM = vim.v.servername

-- Prepend wrapper to PATH so UE inherits it
vim.env.PATH = wrapper_dir .. ":" .. vim.env.PATH
```

**Project detection at startup:**
```lua
local function detect_project_at_startup()
    local dir = vim.loop.cwd()
    while dir and dir ~= "/" do
        local files = vim.fn.glob(dir .. "/*.uproject", false, true)
        if #files > 0 then
            local project_name = vim.fn.fnamemodify(files[1], ":t:r")
            vim.env.NVIM_UE_PROJECT = project_name
            -- Write .projectdir file for wrapper respawn
            local projectdir_file = "/tmp/ue-nvim-" .. project_name .. ".projectdir"
            vim.fn.writefile({dir}, projectdir_file)
            return
        end
        dir = vim.fn.fnamemodify(dir, ":h")
    end
end
```

**Socket cleanup on exit:**
```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        local socket = vim.v.servername
        if socket and socket ~= "" then
            vim.fn.delete(socket)
        end
    end,
})
```

### 5. HiDPI Fix: `fake_dpi.so`

**Location**: `~/UnrealEngine/bin/fake_dpi.so`

UE's Slate UI auto-detects DPI and quantizes into coarse steps (1.0, 1.5, 2.0, etc.). On the Z13's high-DPI display, the auto-detected DPI results in tiny UI elements. We intercept `SDL_GetDisplayDPI()` and force 144 DPI, giving a comfortable 1.5x scale factor.

Compile:
```bash
gcc -shared -fPIC -o fake_dpi.so fake_dpi.c
```

## Critical Findings & Workarounds

### Finding 1: `serverstart()` is broken on nvim v0.12.2

**Problem**: `vim.fn.serverstart('/tmp/ue-nvim-MyProject.sock')` returns a path but never creates the actual socket file. The plugin's `serverstart()` call silently fails.

**Solution**: Use `vim.v.servername` instead — nvim already creates a random socket at startup in `/run/user/1000/nvim.<pid>.0`. We pass this path to UE via the `NVIM` environment variable.

```lua
-- BAD: serverstart() returns path but socket never appears
vim.env.NVIM = vim.fn.serverstart('/tmp/predictable.sock')  -- broken

-- GOOD: use v:servername (random but valid)
vim.env.NVIM = vim.v.servername  -- works
```

### Finding 2: UE passes `--server /path` (space-separated)

**Problem**: UE's `ExecProcess()` calls nvim like:
```bash
nvim --server /run/user/1000/nvim.12345.0 --remote /path/to/file.cpp
```

The wrapper must parse both `--server=/path` and `--server /path` forms.

**Solution**: Use an `EXPECT_SERVER` flag in the argument loop:
```bash
for arg in "$@"; do
    if [[ "$EXPECT_SERVER" == "true" ]]; then
        SERVER_SOCKET="$arg"
        EXPECT_SERVER=false
    fi
    if [[ "$arg" == "--server" ]]; then
        EXPECT_SERVER=true
    fi
done
```

### Finding 3: `xdg-terminal-exec` run with `&` in UE's context gets killed

**Problem**: When the wrapper spawns a terminal with `xdg-terminal-exec nvim ... &`, the process is a child of UE's exec call. When UE's `ExecProcess()` returns, the entire process tree is terminated, killing the terminal before nvim even starts.

**Solution**: Use `setsid` to create a new session, completely detaching from UE's process tree:
```bash
setsid bash -c "xdg-terminal-exec nvim --listen '$SERVER_SOCKET' '$PROJECT_DIR'" &
```

### Finding 4: `timeout 3` prevents UE from freezing

**Problem**: `nvim --server DEAD_SOCKET --remote file` hangs **indefinitely** — nvim has no built-in socket timeout. UE's `ExecProcess()` waits for the command to complete, freezing the editor. We cannot simply check `[[ -S "$SOCKET" ]]` because a stale socket file can exist while the process is dead (zombie socket).

**Solution**: Wrap a lightweight socket probe in `timeout 3`:
```bash
timeout 3 nvim --server "$SOCKET" --remote-send "<Esc>" 2>/dev/null
```
- Exit 0: socket alive — forward the real remote command
- Exit 124: timeout (socket dead) — respawn nvim
- The real command (`--remote file`) is NOT wrapped in timeout because opening a file + LSP attach may take >3 seconds

### Finding 5: Stale sockets must be removed before respawn

**Problem**: When nvim crashes or `VimLeavePre` cleanup fails, the socket file at `/run/user/1000/nvim.*.0` may persist. A new nvim instance cannot bind to that path if the stale file exists.

**Solution**: `rm -f "$SERVER_SOCKET"` immediately before spawning the new nvim:
```bash
rm -f "$SERVER_SOCKET"
setsid bash -c "xdg-terminal-exec nvim --listen '$SERVER_SOCKET' '$PROJECT_DIR'" &
```

### Finding 6: `hyprctl dispatch exec` forces terminal onto current workspace

**Problem**: `xdg-terminal-exec` on Hyprland/Wayland may spawn the terminal on a different workspace than UE, making it appear "lost" to the user.

**Solution**: On Hyprland, use `hyprctl dispatch exec [workspace current]` to force the terminal onto the same workspace as the UE editor:
```bash
if command -v hyprctl &>/dev/null; then
    hyprctl dispatch exec "[workspace current] xdg-terminal-exec nvim --listen $SERVER_SOCKET $PROJECT_DIR"
else
    xdg-terminal-exec nvim --listen "$SERVER_SOCKET" "$PROJECT_DIR" &
fi
```

### Finding 7: Random socket paths require `.projectdir` files

**Problem**: Since we can't use predictable socket paths (see Finding 1), the wrapper receives a random path like `/run/user/1000/nvim.194495.0`. When respawning, it needs to know which project directory to open.

**Solution**: The nvim config writes a `.projectdir` file:
```lua
local projectdir_file = "/tmp/ue-nvim-" .. project_name .. ".projectdir"
vim.fn.writefile({dir}, projectdir_file)
```

The wrapper reads this file to find the project directory:
```bash
PROJECTDIR_FILE="/tmp/ue-nvim-${PROJECT_NAME}.projectdir"
PROJECT_DIR=$(cat "$PROJECTDIR_FILE")
```

**Fallback**: If no `.projectdir` is found, the wrapper walks up from the C++ file path to find the `.uproject` file.

### Finding 8: PATH must be set in nvim's jobstart environment

**Problem**: `jobstart()` (used by the plugin to launch UE) creates a fresh environment from `vim.fn.environ()`. Even if the wrapper is in the user's shell PATH, it won't be there when UE is spawned from nvim.

**Solution**: Explicitly prepend the wrapper directory to `vim.env.PATH` before calling the plugin's `setup()`:
```lua
local wrapper_dir = vim.fn.expand("~/UnrealEngine/bin/wrappers")
vim.env.PATH = wrapper_dir .. ":" .. vim.env.PATH
```

### Finding 9: `VimLeavePre` should delete `v:servername`, not a predictable path

**Problem**: Early versions cleaned up `/tmp/ue-nvim-PROJECT.sock`, but since we're using `v:servername`, the actual socket is at a random path.

**Solution**: Delete `vim.v.servername` on exit:
```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        local socket = vim.v.servername
        if socket and socket ~= "" then
            vim.fn.delete(socket)
        end
    end,
})
```

### Finding 10: Setting Neovim as default editor requires `BaseEditor.ini` patch

**Problem**: Even with the plugin enabled, UE still defaults to "Visual Studio Code" or "Rider" as the active source code accessor. Manually changing Edit → Editor Preferences → Source Code → Neovim for every project is tedious and error-prone.

**Solution**: Patch `Engine/Config/BaseEditor.ini` to set `PreferredAccessor=NeovimSourceCodeAccess`:
```ini
[/Script/SourceCodeAccess.SourceCodeAccessSettings]
PreferredAccessor=NeovimSourceCodeAccess
```

This is engine-wide: all projects on this machine use Neovim by default. The `setup-ue-neovim.sh` script does this automatically.

## Setup Instructions

### 1. Install Unreal Engine

Download a Linux binary release from Epic and run:
```bash
./scripts/install-unreal-engine.sh
```

This installs:
- UE to `~/UnrealEngine/<version>/`
- Launcher at `~/UnrealEngine/bin/ue-<version>`
- nvim wrapper at `~/UnrealEngine/bin/wrappers/nvim`
- `fake_dpi.so` for HiDPI scaling
- Icons, MIME types, and `.desktop` entries

### 2. Configure Neovim

Run the setup script (requires LazyVim):
```bash
./scripts/setup-ue-neovim.sh
```

This creates `~/.config/nvim/lua/plugins/ue.lua` with the full integration config.

### 3. Build the Official Plugin

The official plugin must be built from source:
```bash
cd ~/UnrealEngine/5.5.4/Engine/Plugins/Developer/NeovimSourceCodeAccess
# Follow the plugin's build instructions (typically requires RunUAT)
```

### 4. Auto-Configuration (done by setup script)

The `setup-ue-neovim.sh` script automatically performs two engine-wide patches so you never need to manually configure UE per-project.

**Important:** Run this script **after** building and installing the official plugin (Step 3). If the plugin isn't on disk yet, the script will warn you and skip the patch — just re-run it after the plugin is installed.

**A) Enable Plugin Globally**
Patches the plugin's `.uplugin` descriptor to add `"EnabledByDefault": true`:
- The plugin loads for **all projects** on this machine
- **No `.uproject` modification needed** — remove the `NeovimSourceCodeAccess` entry from your `.uproject` if you had it
- Projects can still opt out by explicitly adding `"Enabled": false` to their `.uproject`

**B) Set Neovim as Default Source Code Editor**
Patches `Engine/Config/BaseEditor.ini` to add:
```ini
[/Script/SourceCodeAccess.SourceCodeAccessSettings]
PreferredAccessor=NeovimSourceCodeAccess
```
- Neovim is pre-selected as the active source code accessor in UE
- **No manual Edit → Editor Preferences → Source Code step needed**
- Applies to all projects on this machine

If you need to do either step manually, see the script source or run the commands by hand.

### 5. Generate LSP Cache (one-time per project)

In nvim, with your UE project open:
```vim
:UnrealEngine lsp
```

This generates `compile_commands.json` and `.clangd` config for the project.

## Workflow

### Daily Workflow

1. **Start nvim in project directory:**
   ```bash
   cd ~/projects/MyGame && nvim .
   ```
   nvim auto-detects the UE project and writes the `.projectdir` file.

2. **Launch UE from nvim:**
   ```vim
   :UnrealEngine open
   ```
   Or press `<leader>uo` (default: Space+uo)

3. **Open C++ files from UE:**
   - In Content Browser, switch to C++ Classes view
   - Double-click any class
   - File opens in your running nvim instance

4. **Build from nvim:**
   ```vim
   :UnrealEngine build
   ```
   Or `<leader>ub`

### Manual UE Launch

You can also launch UE directly:
```bash
ue-5.5.4 MyGame.uproject
```

The launcher still works with the wrapper because it prepends `~/UnrealEngine/bin/wrappers` to PATH.

## Troubleshooting

### Files not opening in nvim

1. Make sure you launched UE **from nvim** (`:UnrealEngine open`), not manually
2. Check the wrapper debug log:
   ```bash
   tail -f /tmp/nvim-wrapper-debug.log
   ```
3. Verify the `.projectdir` file exists:
   ```bash
   cat /tmp/ue-nvim-MyGame.projectdir
   ```

### UE freezes when clicking C++ class

This means the wrapper isn't being used or the `timeout 3` isn't working. Check:
1. `which nvim` should point to `~/UnrealEngine/bin/wrappers/nvim`
2. The wrapper is executable: `chmod +x ~/UnrealEngine/bin/wrappers/nvim`
3. The debug log for "Socket dead or timeout" messages

### LSP not working

Run `:UnrealEngine lsp` to regenerate `compile_commands.json`. Verify it exists:
```bash
ls ~/UnrealEngine/5.5.4/compile_commands.json
```

### Multiple projects

Each project gets its own tagged nvim instance via `.projectdir` files:
```
/tmp/ue-nvim-MyGame.projectdir
/tmp/ue-nvim-OtherGame.projectdir
```

The wrapper automatically resolves the correct project based on the file path or socket pattern.

### Socket cleanup not working

If you see stale sockets in `/run/user/1000/`:
```bash
rm /run/user/1000/nvim.*.0
```

### P4V opens `.uproject` files as text instead of Unreal Editor

**Problem**: Double-clicking a `.uproject` file in P4V opens it as plain text (JSON) instead of launching Unreal Editor.

**Root cause**: `.uproject` files are JSON, so `xdg-mime` content sniffing returns `application/json`. P4V uses `xdg-open` which respects MIME types, while Nautilus uses extension-based matching and works fine.

**Solution**: The installer script installs `perl-file-mimeinfo` and registers a magic rule that identifies `.uproject` files by their distinctive `{"FileVersion":` header (priority 80, higher than JSON). This ensures `xdg-mime query filetype` returns `application/x-uproject`.

If you're still seeing this after installation:
```bash
# Verify perl-file-mimeinfo is installed
which mimetype || sudo pacman -S perl-file-mimeinfo

# Verify MIME type detection
xdg-mime query filetype /path/to/your.uproject
# Should return: application/x-uproject

# If it still returns application/json, force the association:
xdg-mime default unreal-engine-5.5.4.desktop application/x-uproject
```

The `VimLeavePre` autocmd should clean these up automatically. If nvim crashes, manual cleanup may be needed.

## Files in This Repo

| File | Description |
|---|---|
| `scripts/install-unreal-engine.sh` | Standalone UE binary installer |
| `scripts/setup-ue-neovim.sh` | Neovim/LazyVim configuration for UE dev |
| `templates/unreal-engine/nvim-wrapper.sh` | Smart nvim wrapper (dead socket detection, respawn) |
| `templates/unreal-engine/fake_dpi.c` | HiDPI interceptor (force 144 DPI) |
| `templates/unreal-engine/*.png` | Application icons |
| `templates/unreal-engine/unreal-engine.xml` | MIME type for `.uproject` files |

## References

- [mbwilding/UnrealEngine.nvim](https://github.com/mbwilding/UnrealEngine.nvim) — Official UE nvim plugin
- [Unreal Engine Linux Binaries](https://www.unrealengine.com/linux) — Epic's official Linux downloads
- [Omarchy Linux](https://omarchy.org/) — Arch-based distro with Hyprland
- [ROG Flow Z13 Linux Guide](https://github.com/ib99/ASUS-ROG-Flow-Z13-2025-Linux-Guide-Omarchy-CachyOS-Kernel) — Hardware-specific Linux setup
