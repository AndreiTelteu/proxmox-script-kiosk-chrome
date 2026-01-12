#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
CTID="${CTID:-120}"
HOSTNAME="${HOSTNAME:-kiosk}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_GB="${DISK_GB:-4}"
MEM_MB="${MEM_MB:-768}"
CORES="${CORES:-2}"
URL="${URL:-https://example.com}"
# ====================

if [[ $EUID -ne 0 ]]; then
  echo "Run as root on the Proxmox host."
  exit 1
fi

if ! ls /dev/dri/card* &>/dev/null; then
  echo "ERROR: No /dev/dri/card* found. Is amdgpu driver loaded?"
  exit 1
fi

echo "[1/11] Picking a Debian 12 template..."
pveam update >/dev/null
TPL="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|gz)$' | tail -n1 || true)"
if [[ -z "${TPL}" ]]; then
  echo "Could not find a debian-12 template."
  exit 1
fi

if ! pveam list local | awk '{print $1}' | grep -qx "local:vztmpl/${TPL}"; then
  echo "[2/11] Downloading template ${TPL}..."
  pveam download local "${TPL}"
else
  echo "[2/11] Template already present."
fi

echo "[3/11] Creating container CTID=${CTID}..."
pct create "${CTID}" "local:vztmpl/${TPL}" \
  --hostname "${HOSTNAME}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --memory "${MEM_MB}" \
  --cores "${CORES}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 0 \
  --onboot 1 \
  --start 0

echo "[4/11] Adding GPU + input passthrough to container config..."
CONF="/etc/pve/lxc/${CTID}.conf"
cp -n "${CONF}" "${CONF}.bak" 2>/dev/null || true

cat >> "${CONF}" <<'EOF'

# --- AMD GPU Kiosk Passthrough ---
lxc.apparmor.profile: unconfined

# DRM (GPU)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir

# Input devices
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir

# TTY/console access (cgroup only)
lxc.cgroup2.devices.allow: c 4:* rwm
lxc.cgroup2.devices.allow: c 5:* rwm
EOF

echo "[5/11] Disabling host getty on tty1..."
systemctl disable --now getty@tty1.service 2>/dev/null || true

echo "[6/11] Creating host-side TTY mount helper service..."
cat > /etc/systemd/system/lxc-tty-mount@.service <<'EOF'
[Unit]
Description=Mount TTYs into LXC container %i
After=pve-container@%i.service
Requires=pve-container@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 2; ROOTFS=$(lxc-info -n %i -c lxc.rootfs.path | cut -d= -f2 | xargs); touch ${ROOTFS}/dev/tty0 ${ROOTFS}/dev/tty1 2>/dev/null; mount --bind /dev/tty0 ${ROOTFS}/dev/tty0; mount --bind /dev/tty1 ${ROOTFS}/dev/tty1'
ExecStop=/bin/bash -c 'ROOTFS=$(lxc-info -n %i -c lxc.rootfs.path | cut -d= -f2 | xargs); umount ${ROOTFS}/dev/tty0 2>/dev/null; umount ${ROOTFS}/dev/tty1 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "lxc-tty-mount@${CTID}.service"

echo "[7/11] Starting container..."
pct start "${CTID}"
sleep 2

echo "[8/11] Mounting TTYs into container..."
systemctl start "lxc-tty-mount@${CTID}.service"
sleep 1

echo "[9/11] Installing packages..."
pct exec "${CTID}" -- bash -lc "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  xserver-xorg \
  xserver-xorg-video-amdgpu \
  xinit \
  x11-xserver-utils \
  dbus-x11 \
  openbox \
  chromium \
  unclutter \
  mesa-utils \
  libgl1-mesa-dri \
  libglx-mesa0 \
  ca-certificates"

echo "[10/11] Writing kiosk startup scripts..."
pct exec "${CTID}" -- bash -lc "usermod -aG video,render,input,tty root 2>/dev/null || true"

pct exec "${CTID}" -- bash -lc "cat > /usr/local/bin/kiosk-session.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

xset s off
xset -dpms
xset s noblank

unclutter -idle 0.5 -root &

openbox-session &
sleep 1

exec chromium \\
  --no-sandbox \\
  --kiosk \\
  --no-first-run \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-translate \\
  --disable-features=TranslateUI \\
  --autoplay-policy=no-user-gesture-required \\
  --use-gl=egl \\
  --enable-features=VaapiVideoDecoder \\
  '${URL}'
EOS
chmod +x /usr/local/bin/kiosk-session.sh"

pct exec "${CTID}" -- bash -lc "cat > /etc/systemd/system/kiosk-tty1.service <<'EOS'
[Unit]
Description=Chromium Kiosk on tty1 (AMD GPU)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/bin/mkdir -p /run/user/0
ExecStartPre=/bin/chmod 700 /run/user/0
ExecStart=/usr/bin/startx /usr/local/bin/kiosk-session.sh -- :0 vt1 -nolisten tcp -nocursor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOS"

pct exec "${CTID}" -- bash -lc "systemctl daemon-reload && systemctl enable kiosk-tty1.service"

echo "[11/11] Starting kiosk service..."
pct exec "${CTID}" -- systemctl start kiosk-tty1.service

cat <<EOF

========================================
 KIOSK CONTAINER CREATED: CTID ${CTID}
========================================

Monitor should show Chromium at: ${URL}

TROUBLESHOOTING:
  pct exec ${CTID} -- journalctl -u kiosk-tty1.service -b --no-pager
  pct exec ${CTID} -- cat /var/log/Xorg.0.log

  # Verify TTYs are mounted:
  ls -la /var/lib/lxc/${CTID}/rootfs/dev/tty*

CHANGE URL:
  pct exec ${CTID} -- nano /usr/local/bin/kiosk-session.sh
  pct exec ${CTID} -- systemctl restart kiosk-tty1.service

EOF