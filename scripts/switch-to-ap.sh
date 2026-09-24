#!/usr/bin/env bash
set -euo pipefail

run_nmcli() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    nmcli "$@"
  else
    sudo nmcli "$@"
  fi
}

if run_nmcli -t -f NAME connection show | grep -Fxq emergency-web-pi-upstream; then
  run_nmcli connection down emergency-web-pi-upstream 2>/dev/null || true
  run_nmcli connection modify emergency-web-pi-upstream connection.autoconnect no || true
fi

run_nmcli connection up pi-kiwix-ap