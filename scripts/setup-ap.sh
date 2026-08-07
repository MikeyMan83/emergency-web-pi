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
: "${AP_DHCP_START:=10.42.0.10}"
: "${AP_DHCP_END:=10.42.0.50}"
: "${AP_DHCP_LEASE:=24h}"

if [[ ${#AP_PASSPHRASE} -lt 8 || ${#AP_PASSPHRASE} -gt 63 ]]; then
  echo "AP_PASSPHRASE must be 8-63 characters for WPA2." >&2
  exit 1
fi

echo "==> Installing AP packages"
sudo apt-get update -y
sudo apt-get install -y hostapd dnsmasq

echo "==> Configuring dhcpcd static address"
sudo sed -i '/^# PI-KIWIX-SURVIVAL AP START$/,/^# PI-KIWIX-SURVIVAL AP END$/d' /etc/dhcpcd.conf
sudo tee -a /etc/dhcpcd.conf >/dev/null <<EOF
# PI-KIWIX-SURVIVAL AP START
interface ${AP_INTERFACE}
static ip_address=${AP_ADDRESS}
nohook wpa_supplicant
# PI-KIWIX-SURVIVAL AP END
EOF

echo "==> Writing dnsmasq config"
sudo tee /etc/dnsmasq.d/pi-kiwix-survival.conf >/dev/null <<EOF
interface=${AP_INTERFACE}
bind-interfaces
dhcp-range=${AP_DHCP_START},${AP_DHCP_END},${AP_DHCP_LEASE}
EOF

echo "==> Writing hostapd config"
sudo tee /etc/hostapd/hostapd.conf >/dev/null <<EOF
country_code=US
interface=${AP_INTERFACE}
ssid=${AP_SSID}
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

echo "==> Enabling hostapd config path"
if grep -q '^DAEMON_CONF=' /etc/default/hostapd; then
  sudo sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd >/dev/null
fi

echo "==> Enabling services"
sudo systemctl unmask hostapd || true
sudo systemctl enable --now hostapd
sudo systemctl enable --now dnsmasq
sudo systemctl restart dhcpcd

echo
echo "AP mode configured. Connect to SSID: ${AP_SSID}"
echo "Kiwix URL: http://10.42.0.1:8080"
