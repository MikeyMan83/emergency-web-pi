#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MikeyMan83/pi-kiwix-survival.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BOOTSTRAP_USER="${BOOTSTRAP_USER:-${SUDO_USER:-$USER}}"
DEFAULT_HOME="$(getent passwd "$BOOTSTRAP_USER" | cut -d: -f6 || true)"
if [ -z "$DEFAULT_HOME" ]; then
  DEFAULT_HOME="$HOME"
fi
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_HOME/pi-kiwix-survival}"

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

if ! command -v apt-get >/dev/null 2>&1; then
  log "ERROR: This bootstrap script expects Raspberry Pi OS (Debian-based)."
  exit 1
fi

log "Updating package index and ensuring prerequisites..."
sudo apt-get update -y
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
  log "Repository exists, pulling latest..."
  git -C "$INSTALL_DIR" fetch --all --prune
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only
fi

if id -u "$BOOTSTRAP_USER" >/dev/null 2>&1; then
  sudo chown -R "$BOOTSTRAP_USER":"$BOOTSTRAP_USER" "$INSTALL_DIR"
fi

if [ -n "${BOOTSTRAP_GITHUB_TOKEN:-}" ]; then
  mkdir -p "$INSTALL_DIR/secrets"
  printf '%s' "$BOOTSTRAP_GITHUB_TOKEN" > "$INSTALL_DIR/secrets/github_token"
  chmod 600 "$INSTALL_DIR/secrets/github_token"
  log "Wrote token file to $INSTALL_DIR/secrets/github_token"
fi

cd "$INSTALL_DIR"

if [ -n "${BOOTSTRAP_GITHUB_URL:-}" ] || [ -n "${BOOTSTRAP_SYNC_INTERVAL_SECONDS:-}" ] || [ -n "${BOOTSTRAP_KIWIX_PORT:-}" ]; then
  export BOOTSTRAP_GITHUB_URL="${BOOTSTRAP_GITHUB_URL:-}"
  export BOOTSTRAP_SYNC_INTERVAL_SECONDS="${BOOTSTRAP_SYNC_INTERVAL_SECONDS:-}"
  export BOOTSTRAP_KIWIX_PORT="${BOOTSTRAP_KIWIX_PORT:-}"
fi

log "Running installer..."
./scripts/install.sh

log "Bootstrap complete."