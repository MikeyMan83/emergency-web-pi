#!/usr/bin/env bash
set -euo pipefail

if ! command -v raspi-config >/dev/null 2>&1; then
  echo "raspi-config not found. This script requires Raspberry Pi OS." >&2
  exit 1
fi

echo "Enabling overlay filesystem (read-only root) ..."
sudo raspi-config nonint enable_overlayfs

echo
echo "Overlay filesystem enabled. Reboot required."
echo "After reboot, root filesystem is read-only and more resilient to unclean power loss."
echo "When you need to update system packages or scripts, temporarily disable overlayfs:"
echo "  sudo raspi-config nonint disable_overlayfs"
