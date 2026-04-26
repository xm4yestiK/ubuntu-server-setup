#!/bin/bash
# Mengaktifkan strict mode: script akan berhenti seketika (fail-fast) jika ada command gagal atau variabel kosong
set -euo pipefail
# Memaksa APT berjalan dalam mode non-interaktif
export DEBIAN_FRONTEND=noninteractive

# Menarik Doppler Service Token dari file statis lokal (Out-of-Band secret pattern)
DOPPLER_TOKEN=$(cat /etc/server-secrets/doppler.txt)

# Memperbarui index repository dan OS packages
apt-get update
apt-get upgrade -y

# Menginstal tool esensial infrastruktur
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git

# Doppler Setup: Mengunduh GPG key dan mendaftarkan repository APT resmi Doppler
curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
apt-get update
apt-get install -y doppler

# Menginjeksi token otentikasi Doppler secara global (scope /)
doppler configure set token ${DOPPLER_TOKEN} --scope /

# Menarik rahasia (Tailscale & Cloudflare) langsung dari API Doppler ke memori lokal
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain --token="${DOPPLER_TOKEN}")
CLOUDFLARED_TOKEN=$(doppler secrets get CLOUDFLARED_TOKEN --plain --token="${DOPPLER_TOKEN}")

# Cloudflared Setup via Official APT Repository
# Menambahkan GPG key resmi Cloudflare untuk validasi kriptografi
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
# Mendaftarkan repository APT Cloudflare
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
# Menginstal cloudflared melalui package manager
apt-get update
apt-get install -y cloudflared

# Mendaftarkan cloudflared sebagai background service systemd menggunakan token dari Doppler
cloudflared service install "${CLOUDFLARED_TOKEN}"

# Core Stack: Menginstal Podman (daemonless container engine)
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

# Tailscale Setup: Instalasi, aktivasi daemon, dan Zero-Touch Authentication
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# Firewall Hardening (Zero-Trust Network): Hanya menerima SSH dan traffic VPN internal
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable

# Garbage collection (pembersihan sistem)
apt-get autoremove -y
apt-get clean
