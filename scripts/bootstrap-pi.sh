#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MikeyMan83/pi-kiwix-survival.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEFAULT_PROFILE_URL="https://raw.githubusercontent.com/MikeyMan83/pi-kiwix-survival/main/profiles/medical-survival-zimlist.txt"
BOOTSTRAP_USER="${BOOTSTRAP_USER:-${SUDO_USER:-$USER}}"
DEFAULT_HOME="$(getent passwd "$BOOTSTRAP_USER" | cut -d: -f6 || true)"
if [ -z "$DEFAULT_HOME" ]; then
  DEFAULT_HOME="$HOME"
fi
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_HOME/pi-kiwix-survival}"

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

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

if ! command -v apt-get >/dev/null 2>&1; then
  log "ERROR: This bootstrap script expects a Debian-based Raspberry Pi OS."
  exit 1
fi

log "Updating apt package index..."
sudo apt-get update -y

log "Installing required packages..."
sudo apt-get install -y ca-certificates curl git

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi

if [ "$BOOTSTRAP_USER" != "root" ] && id -u "$BOOTSTRAP_USER" >/dev/null 2>&1 && ! id -nG "$BOOTSTRAP_USER" | grep -qw docker; then
  log "Adding ${BOOTSTRAP_USER} to docker group..."
  sudo usermod -aG docker "$BOOTSTRAP_USER"
fi

if [ ! -d "$INSTALL_DIR/.git" ]; then
  log "Cloning repository into ${INSTALL_DIR}..."
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
else
  log "Repository already present, pulling latest..."
  git -C "$INSTALL_DIR" fetch --all --prune
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only
fi

cd "$INSTALL_DIR"

if id -u "$BOOTSTRAP_USER" >/dev/null 2>&1; then
  sudo chown -R "$BOOTSTRAP_USER":"$BOOTSTRAP_USER" "$INSTALL_DIR"
fi

if [ ! -f .env ]; then
  log "Creating .env from .env.example..."
  cp .env.example .env
fi

mkdir -p zim_data secrets
if [ ! -f secrets/.gitkeep ]; then
  touch secrets/.gitkeep
fi

if [ -n "${BOOTSTRAP_GITHUB_URL:-}" ]; then
  log "Setting GITHUB_URL from BOOTSTRAP_GITHUB_URL"
  set_env_value "GITHUB_URL" "$BOOTSTRAP_GITHUB_URL"
elif grep -Fq 'GITHUB_URL=https://raw.githubusercontent.com/<owner>/<repo>/<branch>/zimlist.txt' .env; then
  log "Setting GITHUB_URL to default medical-survival profile"
  set_env_value "GITHUB_URL" "$DEFAULT_PROFILE_URL"
fi

if [ -n "${BOOTSTRAP_SYNC_INTERVAL_SECONDS:-}" ]; then
  log "Setting SYNC_INTERVAL_SECONDS from BOOTSTRAP_SYNC_INTERVAL_SECONDS"
  set_env_value "SYNC_INTERVAL_SECONDS" "$BOOTSTRAP_SYNC_INTERVAL_SECONDS"
fi

if [ -n "${BOOTSTRAP_KIWIX_PORT:-}" ]; then
  log "Setting KIWIX_PORT from BOOTSTRAP_KIWIX_PORT"
  set_env_value "KIWIX_PORT" "$BOOTSTRAP_KIWIX_PORT"
fi

if [ -n "${BOOTSTRAP_GITHUB_TOKEN:-}" ]; then
  log "Writing token to secrets/github_token"
  printf '%s' "$BOOTSTRAP_GITHUB_TOKEN" > secrets/github_token
  chmod 600 secrets/github_token
  set_env_value "GITHUB_TOKEN" ""
  set_env_value "GITHUB_TOKEN_FILE" "/run/secrets/github_token"
fi

if ! grep -Fq 'GITHUB_URL=https://raw.githubusercontent.com/<owner>/<repo>/<branch>/zimlist.txt' .env; then
  log "Bootstrap configuration complete."
else
  log "IMPORTANT: Set a real GITHUB_URL in .env before sync can run."
fi

log "Starting stack..."
sudo docker compose up -d

log "Bootstrap complete. If docker group was just added, log out/in before running docker without sudo."
