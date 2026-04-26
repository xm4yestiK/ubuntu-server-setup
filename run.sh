#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DOPPLER_TOKEN=$(cat /etc/server-secrets/doppler.txt)

apt-get update
apt-get upgrade -y
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git

# Doppler Setup
curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
apt-get update
apt-get install -y doppler
doppler configure set token ${DOPPLER_TOKEN} --scope /

# Ambil Secret dari Doppler
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain --token="${DOPPLER_TOKEN}")
CLOUDFLARED_TOKEN=$(doppler secrets get CLOUDFLARED_TOKEN --plain --token="${DOPPLER_TOKEN}")

# Cloudflared Installation
# Mengunduh paket .deb resmi Cloudflare dan menginstalnya
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb
rm cloudflared.deb

# Menjalankan cloudflared sebagai service menggunakan token dari Doppler
cloudflared service install "${CLOUDFLARED_TOKEN}"

# Core Stack (Podman & Tailscale)
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# Firewall Hardening
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable

apt-get autoremove -y
apt-get clean
