#!/bin/bash
# Menggunakan set -e untuk safety, tapi dengan bypass pada command vendor yang fluktuatif.
set -e
export DEBIAN_FRONTEND=noninteractive

# 1. PRE-FLIGHT CHECKS & SECURE FILE SCAFFOLDING
if [[ "${EUID}" -ne 0 ]]; then
  echo "FATAL ERROR: Script wajib dijalankan dengan privileges root (sudo)."
  exit 1
fi

SECRET_FILE="/opt/doppler.txt"

# Memastikan direktori dan file aman dari akses user non-root
if [[ ! -f "$SECRET_FILE" ]]; then
  touch "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

# Sanitasi string dari dalam file (jika sudah pernah diisi sebelumnya)
DOPPLER_TOKEN=$(cat "$SECRET_FILE" | tr -d '\n\r ')

# Intervensi Manual: Jika token kosong, minta via terminal dan simpan otomatis
if [[ -z "$DOPPLER_TOKEN" ]]; then
  echo "🔒 Doppler Token belum ditemukan di $SECRET_FILE."
  read -s -p "Paste Token Doppler lo di sini: " INPUT_TOKEN
  echo ""
  DOPPLER_TOKEN=$(echo "$INPUT_TOKEN" | tr -d '\n\r ')
  if [[ -z "$DOPPLER_TOKEN" ]]; then
    echo "FATAL ERROR: Input kosong. Eksekusi dihentikan."
    exit 1
  fi
  echo "$DOPPLER_TOKEN" > "$SECRET_FILE"
  echo "✅ Token berhasil di-inject dan diamankan di $SECRET_FILE"
fi

echo "=== MEMULAI INTEGRATED PROVISIONING (DOPPLER + AAPANEL + ZERO-TRUST) ==="

# 2. TOTAL WIPE OUT (Nuklir aaPanel Lama + Bypass Immutable Lock)
echo "[1/10] Membumihanguskan instalasi aaPanel lama (jika ada)..."
if [ -d "/www" ] || [ -L "/www" ] || [ -f "/etc/init.d/bt" ]; then
    /etc/init.d/bt stop &> /dev/null || true
    pkill -9 -f "nginx|mysql|php-fpm|redis|pure-ftpd|mysqld" || true
    chattr -R -i /www /var/www 2>/dev/null || true
    umount -l /www/server/panel/* 2>/dev/null || true
    umount -l /var/www/server/panel/* 2>/dev/null || true
    rm -rf /www /var/www
    rm -f /etc/init.d/bt /usr/bin/bt
    echo "✅ Sistem dibersihkan sampai ke akar."
fi

# 3. BASE DEPENDENCIES
echo "[2/10] Sinkronisasi repositori dan instalasi dependencies..."
apt-get update && apt-get upgrade -y
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git e2fsprogs

# 4. DOPPLER SETUP & SECRET FETCHING
echo "[3/10] Konfigurasi Doppler Control Plane..."
if ! command -v doppler &> /dev/null; then
    curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
    apt-get update && apt-get install -y doppler
fi

doppler configure set token "${DOPPLER_TOKEN}" --scope /
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain)
CLOUDFLARED_TOKEN=$(doppler secrets get CLOUDFLARED_TOKEN --plain)

if [[ -z "$TAILSCALE_AUTH_KEY" || -z "$CLOUDFLARED_TOKEN" ]]; then
  echo "FATAL ERROR: Gagal menarik secret dari Doppler."
  exit 1
fi

# 5. STORAGE ROUTING (XFS Bridge)
echo "[4/10] Mengonfigurasi Storage Routing ke partisi XFS (/var/www)..."
if [ ! -L "/www" ]; then
    mkdir -p /var/www
    ln -s /var/www /www
    echo "✅ Symlink bridge: /www -> /var/www"
fi

# 6. AAPANEL v7.x INSTALLATION
echo "[5/10] Menginstal aaPanel v7.x (Fast Mode)..."
if [ ! -f /etc/init.d/bt ]; then
    wget -O install_panel_en.sh https://www.aapanel.com/script/install_panel_en.sh
    bash install_panel_en.sh aapanel -y || echo "Peringatan: aaPanel mengembalikan non-zero exit."
    rm -f install_panel_en.sh
fi

# 7. CLOUDFLARED SETUP
echo "[6/10] Mengonfigurasi Cloudflare Tunnel..."
if ! command -v cloudflared &> /dev/null; then
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install -y cloudflared
fi
cloudflared service install "${CLOUDFLARED_TOKEN}" || echo "Cloudflared service sudah aktif."

# 8. PODMAN ENGINE SETUP
echo "[7/10] Mengaktifkan Podman Engine & Socket..."
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

# 9. TAILSCALE MESH VPN
echo "[8/10] Menghubungkan ke Tailscale Mesh..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# 10. FIREWALL HARDENING & CLEANUP
echo "[9/10] Zero-Trust Firewall Hardening..."
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable
ufw reload

echo "[10/10] Final Cleanup..."
apt-get autoremove -y && apt-get clean

echo "=== PROVISIONING SELESAI 100% ==="
echo ""
echo "🔐 KREDENSIAL AAPANEL (Akses via IP Tailscale):"
/etc/init.d/bt default
