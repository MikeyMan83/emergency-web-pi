#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="final"

usage() {
  cat <<'EOF'
Usage: scripts/hardware-acceptance.sh [--first-boot|--prebuilt|--final]

Checks the finished appliance on a Raspberry Pi. Run --first-boot while selected
content is still downloading, then run --final after content installation completes.
EOF
}

if [[ "${1:-}" == "--first-boot" ]]; then
  MODE="first-boot"
elif [[ "${1:-}" == "--prebuilt" ]]; then
  MODE="prebuilt"
elif [[ "${1:-}" == "--final" || "$#" -eq 0 ]]; then
  MODE="final"
else
  usage
  exit 2
fi

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  . "$REPO_DIR/.env"
  set +a
fi

: "${ZIM_DATA_DIR:=/var/lib/pi-kiwix-zimdata}"
: "${KIWIX_PORT:=8080}"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_active() {
  systemctl is-active --quiet "$1" || fail "$1 is not active"
  pass "$1 is active"
}

mountpoint -q "$ZIM_DATA_DIR" || fail "$ZIM_DATA_DIR is not mounted"
pass "$ZIM_DATA_DIR is mounted"

nmcli -t -f NAME connection show --active | grep -qx 'pi-kiwix-ap' || fail "Emergency Wi-Fi connection is not active"
pass "Emergency Wi-Fi connection is active"

require_active "pi-kiwix-status.service"
curl -fsS --max-time 10 http://10.42.0.1/status.json >/dev/null || fail "Status page is unavailable"
pass "Status page responds"

if [[ "$MODE" == "first-boot" ]]; then
  [[ -f "$ZIM_DATA_DIR/.content-install-pending" ]] || fail "Initial content marker is missing"
  systemctl is-active --quiet "pi-kiwix-initial-sync.service" || fail "Initial content service is not retrying"
  pass "Initial content installation is pending and retrying"
  exit 0
fi

[[ ! -f "$ZIM_DATA_DIR/.content-install-pending" ]] || fail "Initial content installation is still pending"
zim_count=$(find "$ZIM_DATA_DIR" -maxdepth 1 -type f -name '*.zim' | wc -l)
[[ "$zim_count" -gt 0 ]] || fail "No ZIM files found"
pass "$zim_count ZIM file(s) found"

[[ -s "$ZIM_DATA_DIR/library.xml" ]] || fail "library.xml is missing or empty"
pass "Library index exists"

require_active "pi-kiwix-serve.service"
curl -fsS --max-time 10 "http://10.42.0.1:$KIWIX_PORT/" >/dev/null || fail "Offline library is unavailable"
pass "Offline library responds"

if [[ "$MODE" == "prebuilt" ]]; then
  pass "Prebuilt appliance acceptance complete"
else
  pass "Finished appliance acceptance complete"
fi