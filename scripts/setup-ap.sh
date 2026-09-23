#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env. Run scripts/install.sh first." >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

: "${AP_SSID:?Set AP_SSID in .env}"
: "${AP_PASSPHRASE:?Set AP_PASSPHRASE in .env}"
: "${AP_INTERFACE:=wlan0}"
: "${AP_ADDRESS:=10.42.0.1/24}"
: "${AP_COUNTRY_CODE:=NL}"

if [[ ${#AP_PASSPHRASE} -lt 8 || ${#AP_PASSPHRASE} -gt 63 ]]; then
  echo "AP_PASSPHRASE must be 8-63 characters for WPA2." >&2
  exit 1
fi

if [[ ! "$AP_COUNTRY_CODE" =~ ^[A-Z]{2}$ ]]; then
  echo "AP_COUNTRY_CODE must be a 2-letter uppercase ISO code (example: NL, US, DE)." >&2
  exit 1
fi

if [[ ! "$AP_ADDRESS" =~ / ]]; then
  AP_ADDRESS="${AP_ADDRESS}/24"
fi
AP_HOST="${AP_ADDRESS%%/*}"

echo "==> Installing AP packages"
sudo apt-get update -y
sudo apt-get install -y network-manager dnsmasq-base iw

if ! command -v nmcli >/dev/null 2>&1; then
  echo "nmcli not found after package install. NetworkManager setup cannot continue." >&2
  exit 1
fi

echo "==> Ensuring NetworkManager is active"
sudo systemctl enable --now NetworkManager

echo "==> Removing legacy AP services"
sudo systemctl disable --now hostapd 2>/dev/null || true
sudo systemctl disable --now dnsmasq 2>/dev/null || true
sudo systemctl stop dhcpcd 2>/dev/null || true

echo "==> Configuring NetworkManager hotspot"
sudo nmcli connection delete id pi-kiwix-ap 2>/dev/null || true
sudo nmcli connection add type wifi ifname "$AP_INTERFACE" con-name pi-kiwix-ap autoconnect yes ssid "$AP_SSID"
sudo nmcli connection modify pi-kiwix-ap \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.country "$AP_COUNTRY_CODE" \
  ipv4.method shared \
  ipv4.addresses "$AP_ADDRESS"
sudo nmcli connection modify pi-kiwix-ap \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk "$AP_PASSPHRASE"

echo "==> Configuring captive-portal DNS sinkhole"
sudo mkdir -p /etc/NetworkManager/dnsmasq-shared.d
sudo tee /etc/NetworkManager/dnsmasq-shared.d/emergency-web-pi.conf >/dev/null <<EOF
address=/#/${AP_HOST}
EOF

echo "==> Restarting NetworkManager and bringing AP online"
sudo systemctl restart NetworkManager
sudo nmcli connection up pi-kiwix-ap
sudo iw reg set "$AP_COUNTRY_CODE" || true

echo
echo "AP mode configured. Connect to SSID: ${AP_SSID}"
echo "Kiwix URL: http://${AP_HOST}:8080"
