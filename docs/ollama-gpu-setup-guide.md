# Ollama GPU Setup Guide for AMD Strix Halo

This guide documents how to set up Ollama with GPU acceleration on AMD Strix Halo (Ryzen AI Max+ 395) running Omarchy Linux with CachyOS kernel.

## Overview

AMD Strix Halo features an integrated RDNA 3.5 GPU with up to 40 CUs. For Ollama GPU acceleration, we use the **Vulkan backend** rather than ROCm, as it's simpler to configure and works well with integrated graphics.

## Quick Setup

If you're using the `omarchy-rog-z13-setup` script, simply run phase 8:

```bash
./install.sh --phase 8
```

This handles everything automatically. The rest of this guide explains the manual process.

## Manual Setup

### 1. Install the Correct Package

CachyOS provides separate Ollama packages:

| Package | Backend | Use Case |
|---------|---------|----------|
| `ollama` | CPU only | Default, no GPU |
| `ollama-vulkan` | Vulkan | Recommended for integrated AMD GPUs |
| `ollama-rocm` | ROCm | Discrete AMD GPUs |

Install the Vulkan version:

```bash
# Remove CPU-only version if installed
sudo pacman -R ollama 2>/dev/null || true

# Install Vulkan version
sudo pacman -S ollama-vulkan
```

### 2. Configure the Systemd Service

Create a service override to configure Ollama settings:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
# GPU Configuration for AMD Strix Halo (RDNA 3.5)
# Vulkan backend + iGPU enable required for integrated RDNA 3.5 GPUs
Environment="OLLAMA_VULKAN=1"
Environment="OLLAMA_IGPU_ENABLE=1"
Environment="OLLAMA_FLASH_ATTENTION=1"

# Context length - 256k allows large contexts when needed
# Only uses memory when context is actually utilized
Environment="OLLAMA_CONTEXT_LENGTH=262144"

# Keep models loaded for 24 hours (reduces reload time)
Environment="OLLAMA_KEEP_ALIVE=24h"

# Network binding - localhost only by default (secure)
# Change to 0.0.0.0 if you need network access
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF
```

### 3. Enable and Start the Service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ollama.service
```

### 4. Verify GPU Acceleration

Pull a model and check that it's using GPU:

```bash
ollama pull llama3.2:3b
ollama run llama3.2:3b "Hello"
# In another terminal:
ollama ps
```

The output should show the model loaded with GPU layers, not CPU.

## Network Access Configuration

By default, Ollama only listens on localhost. To allow network access (e.g., from Open WebUI on another machine):

### 1. Update Ollama Binding

Edit the override configuration:

```bash
sudo nano /etc/systemd/system/ollama.service.d/override.conf
```

Change `OLLAMA_HOST` to:

```
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

For CORS support (multiple origins separated by semicolons):

```
Environment="OLLAMA_ORIGINS=https://your-domain.com;http://192.168.1.100:3000"
```

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

### 2. Configure Firewall

If using UFW, allow access from specific IPs:

```bash
# Allow from a specific IP (recommended)
sudo ufw allow from 192.168.1.x to any port 11434 proto tcp

# Or allow from entire subnet (less secure)
sudo ufw allow from 192.168.1.0/24 to any port 11434 proto tcp
```

## Model Storage Locations

Ollama stores models differently depending on how it's run:

| Method | Storage Location |
|--------|------------------|
| `ollama serve` (manual) | `~/.ollama/models/` |
| systemd service | `/var/lib/ollama/` |

If switching from manual to systemd, copy your models:

```bash
sudo cp -r ~/.ollama/models/* /var/lib/ollama/models/
sudo chown -R ollama:ollama /var/lib/ollama/models/
```

## Open WebUI Integration

### Running on a Separate Machine (e.g., Synology NAS)

1. **Docker Compose** (`docker-compose.yml`):

```yaml
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://<ollama-machine-ip>:11434
      - WEBUI_AUTH=true
    volumes:
      - open-webui:/app/backend/data
    restart: unless-stopped

volumes:
  open-webui:
```

2. **Start the container**:

```bash
docker-compose up -d
```

3. **Access**: Navigate to `http://<nas-ip>:3000`

### Reverse Proxy Configuration

If exposing Open WebUI through a reverse proxy, ensure:

1. **WebSocket support** - Required for streaming responses
2. **Adequate timeouts** - 300 seconds recommended for large models

For Synology Reverse Proxy, add custom headers:
- `Upgrade`: `$http_upgrade`
- `Connection`: `upgrade`

## Troubleshooting

### Model Using CPU Instead of GPU

1. Verify you have `ollama-vulkan` installed:
   ```bash
   pacman -Qs ollama
   ```

2. Check Vulkan is working:
   ```bash
   vulkaninfo --summary
   ```

3. Restart the service:
   ```bash
   sudo systemctl restart ollama.service
   ```

4. Check `OLLAMA_IGPU_ENABLE=1` is set in the systemd override:
   ```bash
   cat /etc/systemd/system/ollama.service.d/override.conf | grep IGPU
   ```
   Ollama 0.30.5+ disables integrated GPUs by default. Without this flag, the GPU will be detected but dropped with a log message: `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`.

### Models Not Found After Switching to Systemd

Copy models from user directory to system directory (see Model Storage Locations above).

### Connection Refused from Remote Machine

1. Check `OLLAMA_HOST` is set to `0.0.0.0:11434`
2. Verify firewall allows the connection
3. Check CORS settings if accessing from a web browser

### Slow First Response

This is normal - the model needs to load into VRAM. With `OLLAMA_KEEP_ALIVE=24h`, subsequent requests within 24 hours will be fast.

## Performance Notes

- **VRAM Usage**: Strix Halo shares system RAM as VRAM. With 128GB RAM, you can run very large models
- **Context Length**: 256k context only uses memory when actually utilized
- **Flash Attention**: Enabled by default in our config for better performance
- **Keep Alive**: 24-hour keep-alive means models stay loaded between sessions

## Security Considerations

- Default config binds to localhost only (secure)
- When enabling network access, use firewall rules to restrict to trusted IPs
- Consider OAuth authentication for Open WebUI when exposing to the internet
- Open WebUI supports OAuth providers (Google, GitHub, OIDC) for 2FA
