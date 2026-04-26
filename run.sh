#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Hardcoded Doppler Service Token
DOPPLER_TOKEN="dp.st.prd.nhin3goetNSKSJEjkNMdUrobpFpe8OW1IFYQX1BuTMt"

apt-get update
apt-get upgrade -y
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git

# Doppler CLI Installation
curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
apt-get update
apt-get install -y doppler

doppler configure set token "${DOPPLER_TOKEN}" --scope /

# Secret Fetching (Memory-Only)
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain --token="${DOPPLER_TOKEN}")
CLOUDFLARED_TOKEN=$(doppler secrets get CLOUDFLARED_TOKEN --plain --token="${DOPPLER_TOKEN}")

# Cloudflared Installation via APT
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update
apt-get install -y cloudflared

cloudflared service install "${CLOUDFLARED_TOKEN}"

# Podman Engine Installation
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

# Tailscale Mesh VPN Installation
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# UFW Zero-Trust Hardening
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable

# System Garbage Collection
apt-get autoremove -y
apt-get clean
