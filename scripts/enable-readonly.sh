#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi OS overlayfs backs the root filesystem with tmpfs (RAM):
# writes appear to succeed but are discarded on reboot. If zim_data lives
# on the same partition as root, enabling overlay silently breaks sync.sh -
# new content would vanish every reboot instead of persisting.
#
# This script moves zim_data onto separate, always-writable storage
# (a second SD partition or a USB drive) BEFORE enabling the overlay,
# so the OS partition is protected while content storage stays real.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
MOUNT_POINT="/mnt/zim_data"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env. Run scripts/install.sh first." >&2
  exit 1
fi

echo "==> Available block devices"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
echo
echo "zim_data needs to live on its own partition/device, separate from the"
echo "OS root, before enabling the read-only overlay. Options:"
echo "  - A second partition on the SD card (if you left free space)"
echo "  - A separate USB flash drive or SSD (recommended - simplest and safest)"
echo

read -rp "Enter the device for zim_data storage (example: /dev/sda1), or 'skip' if already configured: " DEV

if [[ "$DEV" == "skip" ]]; then
  echo "Skipping migration - assuming zim_data is already on separate storage."
  CURRENT_ZIM_DIR="$(grep '^ZIM_DATA_DIR=' "$ENV_FILE" | cut -d= -f2- || true)"
  if [[ -z "$CURRENT_ZIM_DIR" || "$CURRENT_ZIM_DIR" == "./zim_data" ]]; then
    echo "WARNING: ZIM_DATA_DIR in .env still points at ./zim_data (same partition as root)." >&2
    echo "Overlay will NOT protect this correctly. Fix ZIM_DATA_DIR before continuing." >&2
    exit 1
  fi
else
  if [[ ! -b "$DEV" ]]; then
    echo "Error: $DEV is not a block device." >&2
    exit 1
  fi

  echo
  echo "WARNING: this ERASES all data on $DEV and formats it ext4."
  read -rp "Type the device name again to confirm ($DEV): " CONFIRM
  if [[ "$CONFIRM" != "$DEV" ]]; then
    echo "Confirmation did not match. Aborting." >&2
    exit 1
  fi

  echo "==> Formatting $DEV as ext4 (label ZIMDATA)"
  sudo mkfs.ext4 -F -L ZIMDATA "$DEV"

  UUID="$(sudo blkid -s UUID -o value "$DEV")"

  echo "==> Mounting at $MOUNT_POINT"
  sudo mkdir -p "$MOUNT_POINT"
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount "$MOUNT_POINT"
  sudo chown "$(id -u):$(id -g)" "$MOUNT_POINT"

  echo "==> Migrating existing content from ./zim_data"
  if [[ -d "$REPO_DIR/zim_data" ]] && [[ -n "$(ls -A "$REPO_DIR/zim_data" 2>/dev/null)" ]]; then
    rsync -a "$REPO_DIR/zim_data"/ "$MOUNT_POINT"/
    echo "Migrated. Original ./zim_data left in place - safe to remove once you've verified the new mount."
  fi

  echo "==> Updating ZIM_DATA_DIR in .env"
  if grep -q '^ZIM_DATA_DIR=' "$ENV_FILE"; then
    awk -v v="$MOUNT_POINT" -F= '
      $1=="ZIM_DATA_DIR" { print "ZIM_DATA_DIR=" v; next }
      { print }
    ' "$ENV_FILE" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf "\nZIM_DATA_DIR=%s\n" "$MOUNT_POINT" >> "$ENV_FILE"
  fi

  echo "==> Restarting kiwix service with the new data path"
  cd "$REPO_DIR"
  sudo systemctl restart pi-kiwix-serve.service
fi

if ! command -v raspi-config >/dev/null 2>&1; then
  echo "raspi-config not found. This script requires Raspberry Pi OS." >&2
  exit 1
fi

echo "==> Enabling overlay filesystem (read-only root) on the SD card"
sudo raspi-config nonint enable_overlayfs

echo
echo "Done. Reboot required."
echo "- Root filesystem: RAM-backed overlay, writes discarded on reboot (protects the SD card)."
echo "- zim_data: real, persistent storage at ${MOUNT_POINT} (or your existing setup), untouched by overlay."
echo "- To update system packages or scripts later, first: sudo raspi-config nonint disable_overlayfs"
