#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

set_env_value() {
  local key="$1"
  local value="$2"
  awk -v k="$key" -v v="$value" -F= '
    BEGIN { updated=0 }
    $1 == k { print k "=" v; updated=1; next }
    { print }
    END { if (!updated) print k "=" v }
  ' .env > .env.tmp
  mv .env.tmp .env
}

echo "==> Checking .env"
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from defaults (published medical-survival profile)."
fi

if [[ -n "${BOOTSTRAP_GITHUB_URL:-}" ]]; then
  set_env_value "GITHUB_URL" "$BOOTSTRAP_GITHUB_URL"
fi
if [[ -n "${BOOTSTRAP_SYNC_INTERVAL_SECONDS:-}" ]]; then
  set_env_value "SYNC_INTERVAL_SECONDS" "$BOOTSTRAP_SYNC_INTERVAL_SECONDS"
fi
if [[ -n "${BOOTSTRAP_KIWIX_PORT:-}" ]]; then
  set_env_value "KIWIX_PORT" "$BOOTSTRAP_KIWIX_PORT"
fi

set -a
. ./.env
set +a

: "${ZIM_DATA_DIR:=./zim_data}"
: "${KIWIX_PORT:=8080}"

echo "==> Checking dependencies"
sudo apt-get update -y
command -v python3 >/dev/null || sudo apt-get install -y python3
command -v aria2c >/dev/null || sudo apt-get install -y aria2
command -v kiwix-serve >/dev/null || sudo apt-get install -y kiwix-tools
command -v kiwix-manage >/dev/null || sudo apt-get install -y kiwix-tools

echo "==> Preparing data directory"
mkdir -p "$ZIM_DATA_DIR"

echo "==> Bootstrapping library.xml from any existing content"
./scripts/rebuild-library.sh

echo "==> Installing kiwix service"
sudo cp scripts/systemd/pi-kiwix-serve.service /etc/systemd/system/
sudo sed -i "s#__REPO_DIR__#$REPO_DIR#g" /etc/systemd/system/pi-kiwix-serve.service

echo "==> Installing sync timer"
sudo cp scripts/systemd/pi-kiwix-sync.service /etc/systemd/system/
sudo cp scripts/systemd/pi-kiwix-sync.timer /etc/systemd/system/
echo "==> Installing boot status page service"
sudo cp scripts/systemd/pi-kiwix-status.service /etc/systemd/system/
sudo sed -i "s#__REPO_DIR__#$REPO_DIR#g" /etc/systemd/system/pi-kiwix-sync.service
sudo sed -i "s#__REPO_DIR__#$REPO_DIR#g" /etc/systemd/system/pi-kiwix-status.service
sudo systemctl daemon-reload
sudo systemctl enable --now pi-kiwix-serve.service
sudo systemctl enable --now pi-kiwix-sync.timer
sudo systemctl enable --now pi-kiwix-status.service
sudo systemctl start pi-kiwix-sync.service

if [[ "${BOOTSTRAP_ENABLE_AP:-0}" == "1" ]]; then
  echo "==> Enabling standalone AP mode"
  ./scripts/setup-ap.sh
fi

IP=$(hostname -I | awk '{print $1}')
echo
echo "Done. Kiwix is live at http://$IP:$KIWIX_PORT"
echo "Boot status page: http://$IP/"
echo "Content updates weekly - check: systemctl list-timers pi-kiwix-sync.timer"
