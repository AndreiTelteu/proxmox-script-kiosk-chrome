
# Proxmox LXC Kiosk with AMD GPU Passthrough

A script to create a lightweight Debian LXC container on Proxmox VE that displays a fullscreen Chromium browser on the host's physical HDMI output.

## Features

- 🖥️ Fullscreen Chromium kiosk on host's physical display (tty1)
- 🎮 AMD integrated GPU passthrough with hardware acceleration
- 🔄 Auto-start on boot
- 🖱️ Cursor auto-hide
- 🔒 Screen blanking disabled
- 📦 Minimal Debian 12 container (~4GB disk)
- 🤝 GPU can be shared with other containers for compute/rendering

## Requirements

- Proxmox VE 7.x or 8.x
- AMD integrated GPU (amdgpu driver)
- HDMI monitor connected to motherboard
- `amdgpu` kernel module loaded (NOT vfio-pci)

### Verify GPU is available

```bash
ls /dev/dri/
# Should show: card0  renderD128

lsmod | grep amdgpu
# Should show amdgpu module loaded
```

> ⚠️ **Do NOT use VFIO passthrough** for this use case. VFIO is for passing the entire GPU to a single VM. For LXC containers sharing the GPU, keep `amdgpu` loaded on the host.

## Installation

### 1. Download the script

```bash
wget https://raw.githubusercontent.com/AndreiTelteu/proxmox-script-kiosk-chrome/main/create-kiosk-ct.sh
chmod +x create-kiosk-ct.sh
```

### 2. Configure (optional)

Edit the script to customize:

```bash
CTID="${CTID:-120}"              # Container ID
HOSTNAME="${HOSTNAME:-kiosk}"    # Container hostname
STORAGE="${STORAGE:-local-lvm}"  # Proxmox storage
BRIDGE="${BRIDGE:-vmbr0}"        # Network bridge
DISK_GB="${DISK_GB:-4}"          # Disk size in GB
MEM_MB="${MEM_MB:-768}"          # Memory in MB
CORES="${CORES:-2}"              # CPU cores
URL="${URL:-https://example.com}" # Kiosk URL
```

Or pass as environment variables:

```bash
CTID=200 URL="https://google.com" ./create-kiosk-ct.sh
```

### 3. Run

```bash
./create-kiosk-ct.sh
```

The script will:
1. Download Debian 12 template (if needed)
2. Create a privileged LXC container
3. Configure GPU and TTY passthrough
4. Install Xorg, Chromium, and AMD drivers
5. Set up auto-starting kiosk service
6. Display the URL on your HDMI monitor

## Usage

### Change the kiosk URL

```bash
pct exec 120 -- nano /usr/local/bin/kiosk-session.sh
pct exec 120 -- systemctl restart kiosk-tty1.service
```

### Restart the kiosk

```bash
pct exec 120 -- systemctl restart kiosk-tty1.service
```

### View logs

```bash
# Kiosk service logs
pct exec 120 -- journalctl -u kiosk-tty1.service -b --no-pager

# Xorg logs
pct exec 120 -- cat /var/log/Xorg.0.log
```

### Stop/start container

```bash
pct stop 120
pct start 120
```

## Sharing GPU with Other Containers

The AMD GPU can be shared with multiple containers. Only **one container can own the display** (tty1), but others can use the GPU for:
- Hardware video encoding/decoding (VA-API)
- OpenGL rendering (offscreen)
- GPU compute

### Add GPU access to another container

Add these lines to `/etc/pve/lxc/<CTID>.conf`:

```
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

Then inside the container:

```bash
apt install mesa-utils libgl1-mesa-dri
glxinfo | grep "OpenGL renderer"
```

## Troubleshooting

### No display output

1. Check if TTYs are mounted:
   ```bash
   ls -la /var/lib/lxc/120/rootfs/dev/tty*
   ```

2. Verify the host service is running:
   ```bash
   systemctl status lxc-tty-mount@120.service
   ```

3. Check Xorg logs for errors:
   ```bash
   pct exec 120 -- cat /var/log/Xorg.0.log | grep -E "(EE|Fatal)"
   ```

### "Switching VT failed" error

The TTY mount service may not have started. Run:

```bash
systemctl restart lxc-tty-mount@120.service
pct exec 120 -- systemctl restart kiosk-tty1.service
```

### `/dev/dri` not found

The `amdgpu` driver is not loaded. Check:

```bash
lsmod | grep amdgpu
dmesg | grep -i amdgpu
```

If you previously configured VFIO passthrough, undo it:

```bash
rm -f /etc/modprobe.d/vfio.conf
rm -f /etc/modprobe.d/blacklist-amdgpu.conf
update-initramfs -u -k all
reboot
```

### Chromium crashes

Check if GPU acceleration is working:

```bash
pct exec 120 -- glxinfo | head -20
```

If not, try disabling GPU flags in `/usr/local/bin/kiosk-session.sh`:

```bash
# Remove these lines:
--use-gl=egl
--enable-features=VaapiVideoDecoder
```

## Uninstall

```bash
# Stop and destroy container
pct stop 120
pct destroy 120

# Remove host TTY mount service
systemctl disable --now lxc-tty-mount@120.service
rm /etc/systemd/system/lxc-tty-mount@.service
systemctl daemon-reload

# Re-enable host getty on tty1
systemctl enable --now getty@tty1.service
```

## Security Considerations

This setup uses a **privileged container** with **AppArmor disabled** to access host devices. This is less secure than a standard container. Consider:

- Running only trusted software in the kiosk
- Using network isolation if the kiosk doesn't need full network access
- Keeping the container updated

## License

MIT
