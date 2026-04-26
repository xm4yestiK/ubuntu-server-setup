#!/bin/bash
set -euo pipefail
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
  # read -s membuat input tidak terlihat di layar demi keamanan (anti-shoulder surfing)
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

# 2. BASE DEPENDENCIES
apt-get update && apt-get upgrade -y
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git

# 3. DOPPLER SETUP (Idempotent)
if ! command -v doppler &> /dev/null; then
    curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
    apt-get update && apt-get install -y doppler
fi

doppler configure set token "${DOPPLER_TOKEN}" --scope /

# 4. FETCH & VALIDATE SECRETS
echo "Menarik konfigurasi dari Doppler Control Plane..."
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain --token="${DOPPLER_TOKEN}")
CLOUDFLARED_TOKEN=$(doppler secrets get CLOUDFLARED_TOKEN --plain --token="${DOPPLER_TOKEN}")

if [[ -z "$TAILSCALE_AUTH_KEY" || -z "$CLOUDFLARED_TOKEN" ]]; then
  echo "FATAL ERROR: Gagal menarik secret. Token invalid atau nama secret salah."
  exit 1
fi

# 5. CLOUDFLARED SETUP via APT
if ! command -v cloudflared &> /dev/null; then
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install -y cloudflared
fi

cloudflared service install "${CLOUDFLARED_TOKEN}" || echo "Cloudflared service sudah terdaftar, melompati step ini."

# 6. PODMAN ENGINE SETUP
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

# 7. TAILSCALE MESH VPN SETUP
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# 8. ZERO-TRUST FIREWALL HARDENING
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable

# 9. SYSTEM GARBAGE COLLECTION
apt-get autoremove -y
apt-get clean

echo "=== PROVISIONING SELESAI 100% ==="
