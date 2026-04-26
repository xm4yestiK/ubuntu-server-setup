#!/bin/bash
# Mengaktifkan strict mode: script akan berhenti seketika (fail-fast) jika ada command gagal, variabel kosong, atau error pada eksekusi pipeline
set -euo pipefail
# Memaksa APT berjalan dalam mode non-interaktif untuk menghindari script terhenti karena prompt konfirmasi user
export DEBIAN_FRONTEND=noninteractive

# Menarik Doppler Service Token dari file statis lokal (Out-of-Band secret pattern)
DOPPLER_TOKEN=$(cat /etc/server-secrets/doppler.txt)

# Memperbarui index repository dan melakukan patch/upgrade pada semua package bawaan OS ke versi terbaru
apt-get update
apt-get upgrade -y

# Menginstal tool esensial: manipulasi network (curl/wget), kriptografi (gnupg2/ca-certificates), parsing JSON (jq), firewall (ufw), dan version control (git)
apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates ufw jq git

# Mengunduh public GPG key dari Doppler dengan koneksi TLSv1.2, mendekripsi menjadi format dearmor, dan mendaftarkan repository APT resmi Doppler
curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" | tee /etc/apt/sources.list.d/doppler-cli.list
apt-get update
apt-get install -y doppler

# Menginjeksi token otentikasi Doppler secara global pada root directory (scope /) untuk akses Single Source of Truth
doppler configure set token ${DOPPLER_TOKEN} --scope /

# Menarik rahasia Tailscale Auth Key langsung dari API Doppler secara on-the-fly (memory-only, tidak ditulis ke disk)
TAILSCALE_AUTH_KEY=$(doppler secrets get TAILSCALE_AUTH_KEY --plain --token="${DOPPLER_TOKEN}")

# Menginstal Podman (daemonless container engine) dan podman-compose, lalu menyalakan socket-nya agar kompatibel dengan standard Docker API
apt-get install -y podman podman-compose
systemctl enable --now podman.socket

# Mengunduh dan mengeksekusi script instalasi resmi Tailscale, lalu mengaktifkan daemon WireGuard-based VPN-nya via systemd
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# Mengotentikasi dan menyambungkan server ke Tailnet secara headless (tanpa interaksi browser) menggunakan Auth Key, dan menghapus state mesin sebelumnya jika ada (--reset)
tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --reset

# Melakukan hardening jaringan (Zero-Trust Network): hanya membuka port SSH standar dan menerima traffic internal yang berasal dari tunnel VPN tailscale0
ufw allow ssh
ufw allow in on tailscale0
ufw --force enable

# Menjalankan garbage collection pada sistem operasi untuk menghapus orphaned packages dan cache sisa instalasi
apt-get autoremove -y
apt-get clean