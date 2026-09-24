#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$REPO_DIR/config/appliance.example.json"
BASE_IMAGE_PATH=""
OUTPUT_IMAGE_PATH="$REPO_DIR/artifacts/appliance.img"
MANIFEST_PATH=""
ZIM_SOURCE_DIR=""
MIN_ZIM_PARTITION_GB=8
ALLOW_EMPTY_ZIMDATA=0

usage() {
  cat <<'EOF'
Usage:
  scripts/build-appliance-image.sh --base-image <path> [options]

Required:
  --base-image <path>             Local Raspberry Pi OS Lite image path (.img, .img.xz, .zip)

Options:
  --config <path>                 Appliance config JSON (default: config/appliance.example.json)
  --output <path>                 Output appliance image path (default: artifacts/appliance.img)
  --manifest <path>               Output manifest path (default: <output>.manifest.json)
  --zim-source-dir <path>         Directory containing preloaded .zim files
  --min-zim-partition-gb <int>    Minimum dedicated zimdata partition size in GB (default: 8)
  --allow-empty-zimdata           Allow image build without preloaded .zim files
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-image)
      BASE_IMAGE_PATH="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_IMAGE_PATH="$2"
      shift 2
      ;;
    --manifest)
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --zim-source-dir)
      ZIM_SOURCE_DIR="$2"
      shift 2
      ;;
    --min-zim-partition-gb)
      MIN_ZIM_PARTITION_GB="$2"
      shift 2
      ;;
    --allow-empty-zimdata)
      ALLOW_EMPTY_ZIMDATA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_IMAGE_PATH" ]]; then
  echo "--base-image is required." >&2
  usage
  exit 1
fi

BASE_IMAGE_PATH="$(realpath "$BASE_IMAGE_PATH")"
OUTPUT_IMAGE_PATH="$(realpath -m "$OUTPUT_IMAGE_PATH")"
CONFIG_PATH="$(realpath "$CONFIG_PATH")"
if [[ -z "$MANIFEST_PATH" ]]; then
  MANIFEST_PATH="${OUTPUT_IMAGE_PATH}.manifest.json"
fi
MANIFEST_PATH="$(realpath -m "$MANIFEST_PATH")"

require_cmd jq
require_cmd rsync
require_cmd losetup
require_cmd parted
require_cmd mkfs.ext4
require_cmd sha256sum
require_cmd unzip
require_cmd xz
require_cmd chroot
require_cmd systemctl
require_cmd qemu-aarch64-static

if [[ ! -f "$BASE_IMAGE_PATH" ]]; then
  echo "Base image not found: $BASE_IMAGE_PATH" >&2
  exit 1
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config not found: $CONFIG_PATH" >&2
  exit 1
fi
if [[ -n "$ZIM_SOURCE_DIR" && ! -d "$ZIM_SOURCE_DIR" ]]; then
  echo "ZIM source directory not found: $ZIM_SOURCE_DIR" >&2
  exit 1
fi
if [[ -z "$ZIM_SOURCE_DIR" && "$ALLOW_EMPTY_ZIMDATA" -ne 1 ]]; then
  echo "ZIM source directory is required for offline-ready appliance builds." >&2
  echo "Provide --zim-source-dir or pass --allow-empty-zimdata for development-only images." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
SRC_IMAGE="$TMP_DIR/base.img"
LOOP_DEV=""
MOUNT_ROOT="$TMP_DIR/mnt-root"
MOUNT_BOOT="$TMP_DIR/mnt-boot"
MOUNT_ZIM="$TMP_DIR/mnt-zim"

cleanup() {
  set +e
  if mountpoint -q "$MOUNT_ZIM"; then sudo umount "$MOUNT_ZIM"; fi
  if mountpoint -q "$MOUNT_BOOT"; then sudo umount "$MOUNT_BOOT"; fi
  if mountpoint -q "$MOUNT_ROOT/proc"; then sudo umount "$MOUNT_ROOT/proc"; fi
  if mountpoint -q "$MOUNT_ROOT/sys"; then sudo umount "$MOUNT_ROOT/sys"; fi
  if mountpoint -q "$MOUNT_ROOT/dev/pts"; then sudo umount "$MOUNT_ROOT/dev/pts"; fi
  if mountpoint -q "$MOUNT_ROOT/dev"; then sudo umount "$MOUNT_ROOT/dev"; fi
  if mountpoint -q "$MOUNT_ROOT"; then sudo umount "$MOUNT_ROOT"; fi
  if [[ -n "$LOOP_DEV" ]]; then sudo losetup -d "$LOOP_DEV" 2>/dev/null || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT_IMAGE_PATH")" "$MOUNT_ROOT" "$MOUNT_BOOT" "$MOUNT_ZIM"

case "$BASE_IMAGE_PATH" in
  *.img)
    cp "$BASE_IMAGE_PATH" "$SRC_IMAGE"
    ;;
  *.img.xz|*.xz)
    xz -dc "$BASE_IMAGE_PATH" > "$SRC_IMAGE"
    ;;
  *.zip)
    unzip -p "$BASE_IMAGE_PATH" '*.img' > "$SRC_IMAGE"
    ;;
  *)
    echo "Unsupported base image format. Use .img, .img.xz, or .zip." >&2
    exit 1
    ;;
esac

cp "$SRC_IMAGE" "$OUTPUT_IMAGE_PATH"

min_partition_bytes=$(( MIN_ZIM_PARTITION_GB * 1024 * 1024 * 1024 ))
required_partition_bytes=$min_partition_bytes
if [[ -n "$ZIM_SOURCE_DIR" ]]; then
  zim_bytes=$(find "$ZIM_SOURCE_DIR" -type f -name '*.zim' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
  overhead=$(( 1024 * 1024 * 1024 ))
  suggested=$(( zim_bytes + overhead ))
  if (( suggested > required_partition_bytes )); then
    required_partition_bytes=$suggested
  fi
fi

current_size=$(stat -c '%s' "$OUTPUT_IMAGE_PATH")
truncate -s $(( current_size + required_partition_bytes )) "$OUTPUT_IMAGE_PATH"

LOOP_DEV=$(sudo losetup --show -fP "$OUTPUT_IMAGE_PATH")
sudo partprobe "$LOOP_DEV"

free_start_mib=$(sudo parted -m "$LOOP_DEV" unit MiB print free | awk -F: '/free/ {start=$2; end=$3} END {gsub("MiB", "", start); gsub("MiB", "", end); if (start=="" || end=="") exit 1; print start}')
if [[ -z "$free_start_mib" ]]; then
  echo "Could not find free space for zimdata partition." >&2
  exit 1
fi

sudo parted -s "$LOOP_DEV" mkpart primary ext4 "${free_start_mib}MiB" 100%
sudo partprobe "$LOOP_DEV"

ROOT_PART="${LOOP_DEV}p2"
BOOT_PART="${LOOP_DEV}p1"
ZIM_PART="${LOOP_DEV}p3"

if [[ ! -b "$ZIM_PART" ]]; then
  echo "Expected third partition ${ZIM_PART} was not created." >&2
  exit 1
fi

sudo mkfs.ext4 -F -L zimdata "$ZIM_PART"

sudo mount "$ROOT_PART" "$MOUNT_ROOT"
sudo mount "$BOOT_PART" "$MOUNT_BOOT"
sudo mount "$ZIM_PART" "$MOUNT_ZIM"

if [[ -n "$ZIM_SOURCE_DIR" ]]; then
  sudo rsync -a --delete "$ZIM_SOURCE_DIR"/ "$MOUNT_ZIM"/
fi

sudo mkdir -p "$MOUNT_ROOT/var/lib/pi-kiwix-zimdata"
sudo tee -a "$MOUNT_ROOT/etc/fstab" >/dev/null <<'EOF'
LABEL=zimdata /var/lib/pi-kiwix-zimdata ext4 defaults,nofail 0 2
EOF

sudo mkdir -p "$MOUNT_ROOT/opt/emergency-web-pi"
sudo rsync -a --delete \
  --exclude='.git' \
  --exclude='artifacts' \
  --exclude='zim_data' \
  "$REPO_DIR"/ "$MOUNT_ROOT/opt/emergency-web-pi"/

ssid=$(jq -r '.network.ap.ssid' "$CONFIG_PATH")
password=$(jq -r '.network.ap.password' "$CONFIG_PATH")
ap_address=$(jq -r '.network.ap.address' "$CONFIG_PATH")
ap_port=$(jq -r '.network.ap.port' "$CONFIG_PATH")
ap_country=$(jq -r '.network.ap.countryCode // "NL"' "$CONFIG_PATH")
upstream_enabled=$(jq -r '.network.upstream.enabled // false' "$CONFIG_PATH")
upstream_ssid=$(jq -r '.network.upstream.ssid // ""' "$CONFIG_PATH")
upstream_password=$(jq -r '.network.upstream.password // ""' "$CONFIG_PATH")
interval=$(jq -r '.updates.intervalSeconds // 604800' "$CONFIG_PATH")
hostname_cfg=$(jq -r '.system.hostname' "$CONFIG_PATH")
profile=$(jq -r '.content.profile' "$CONFIG_PATH")
snapshot=$(jq -r '.content.snapshot' "$CONFIG_PATH")
version=$(jq -r '.applianceVersion' "$CONFIG_PATH")

if [[ ! "$ap_country" =~ ^[A-Z]{2}$ ]]; then
  echo "network.ap.countryCode must be a two-letter uppercase value (example: NL, US, DE)." >&2
  exit 1
fi

if [[ "$password" == "__GENERATE__" || "$password" == "ChangeThisEmergencyPassword123" ]]; then
  echo "network.ap.password is a placeholder. Run scripts/build-appliance-image.ps1 so the resolved config is generated before image construction." >&2
  exit 1
fi

if [[ "$ap_address" == */* ]]; then
  ap_cidr="$ap_address"
  ap_host="${ap_address%%/*}"
else
  ap_cidr="${ap_address}/24"
  ap_host="$ap_address"
fi

jq --arg p "$password" '.network.ap.password = $p' "$CONFIG_PATH" | sudo tee "$MOUNT_ROOT/opt/emergency-web-pi/config/appliance.local.json" >/dev/null
sudo chown 1000:1000 "$MOUNT_ROOT/opt/emergency-web-pi/config/appliance.local.json" || true

sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/.env.example" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^AP_SSID=.*|AP_SSID=$ssid|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^AP_PASSPHRASE=.*|AP_PASSPHRASE=$password|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^AP_ADDRESS=.*|AP_ADDRESS=${ap_cidr}|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^AP_COUNTRY_CODE=.*|AP_COUNTRY_CODE=${ap_country}|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^SYNC_INTERVAL_SECONDS=.*|SYNC_INTERVAL_SECONDS=$interval|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i "s|^ZIM_DATA_DIR=.*|ZIM_DATA_DIR=/var/lib/pi-kiwix-zimdata|" "$MOUNT_ROOT/opt/emergency-web-pi/.env"
sudo sed -i '/^COMPOSE_SERVICE=/d' "$MOUNT_ROOT/opt/emergency-web-pi/.env"

sudo sed -i "s/__REPO_DIR__/\/opt\/emergency-web-pi/g" "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-serve.service"
sudo sed -i "s/__REPO_DIR__/\/opt\/emergency-web-pi/g" "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-sync.service"
sudo sed -i "s/__REPO_DIR__/\/opt\/emergency-web-pi/g" "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-initial-sync.service"
sudo sed -i "s/__REPO_DIR__/\/opt\/emergency-web-pi/g" "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-status.service"
sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-serve.service" "$MOUNT_ROOT/etc/systemd/system/pi-kiwix-serve.service"
sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-sync.service" "$MOUNT_ROOT/etc/systemd/system/pi-kiwix-sync.service"
sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-initial-sync.service" "$MOUNT_ROOT/etc/systemd/system/pi-kiwix-initial-sync.service"
sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-sync.timer" "$MOUNT_ROOT/etc/systemd/system/pi-kiwix-sync.timer"
sudo cp "$MOUNT_ROOT/opt/emergency-web-pi/scripts/systemd/pi-kiwix-status.service" "$MOUNT_ROOT/etc/systemd/system/pi-kiwix-status.service"

sudo mkdir -p "$MOUNT_ROOT/etc/NetworkManager/system-connections"
sudo tee "$MOUNT_ROOT/etc/NetworkManager/system-connections/pi-kiwix-ap.nmconnection" >/dev/null <<EOF
[connection]
id=pi-kiwix-ap
type=wifi
autoconnect=true

[wifi]
mode=ap
ssid=$ssid
band=bg
country=$ap_country

[wifi-security]
key-mgmt=wpa-psk
psk=$password

[ipv4]
method=shared
address1=${ap_cidr}

[ipv6]
method=ignore
EOF
sudo chmod 600 "$MOUNT_ROOT/etc/NetworkManager/system-connections/pi-kiwix-ap.nmconnection"

if [[ "$upstream_enabled" == "true" ]]; then
  if [[ -z "$upstream_ssid" || ${#upstream_password} -lt 8 || ${#upstream_password} -gt 63 ]]; then
    echo "network.upstream requires a non-empty SSID and WPA2 password when enabled." >&2
    exit 1
  fi

  sudo tee "$MOUNT_ROOT/etc/NetworkManager/system-connections/emergency-web-pi-upstream.nmconnection" >/dev/null <<EOF
[connection]
id=emergency-web-pi-upstream
type=wifi
autoconnect=true
autoconnect-priority=20

[wifi]
ssid=$upstream_ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$upstream_password

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  sudo chmod 600 "$MOUNT_ROOT/etc/NetworkManager/system-connections/emergency-web-pi-upstream.nmconnection"
fi

sudo mkdir -p "$MOUNT_ROOT/etc/NetworkManager/dnsmasq-shared.d"
sudo tee "$MOUNT_ROOT/etc/NetworkManager/dnsmasq-shared.d/emergency-web-pi.conf" >/dev/null <<EOF
address=/#/$ap_host
EOF

sudo mkdir -p "$MOUNT_ROOT/var/lib/pi-kiwix-zimdata"
sudo touch "$MOUNT_ROOT/var/lib/pi-kiwix-zimdata/library.xml"

echo "$hostname_cfg" | sudo tee "$MOUNT_ROOT/etc/hostname" >/dev/null

sudo mount --bind /dev "$MOUNT_ROOT/dev"
sudo mount --bind /dev/pts "$MOUNT_ROOT/dev/pts"
sudo mount --bind /proc "$MOUNT_ROOT/proc"
sudo mount --bind /sys "$MOUNT_ROOT/sys"
sudo cp /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf"
sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_ROOT/usr/bin/"

sudo chroot "$MOUNT_ROOT" /usr/bin/qemu-aarch64-static /bin/bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y kiwix-tools aria2 curl git network-manager dnsmasq-base iw ca-certificates python3
if ! id emergency-web-pi >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/emergency-web-pi --create-home --shell /usr/sbin/nologin emergency-web-pi
fi
chown -R emergency-web-pi:emergency-web-pi /var/lib/pi-kiwix-zimdata /opt/emergency-web-pi
'

sudo systemctl --root "$MOUNT_ROOT" enable NetworkManager.service
sudo systemctl --root "$MOUNT_ROOT" enable pi-kiwix-serve.service
sudo systemctl --root "$MOUNT_ROOT" enable pi-kiwix-initial-sync.service
sudo systemctl --root "$MOUNT_ROOT" enable pi-kiwix-sync.timer
sudo systemctl --root "$MOUNT_ROOT" enable pi-kiwix-status.service

sudo umount "$MOUNT_ROOT/proc"
sudo umount "$MOUNT_ROOT/sys"
sudo umount "$MOUNT_ROOT/dev/pts"
sudo umount "$MOUNT_ROOT/dev"

sudo umount "$MOUNT_ZIM"
sudo umount "$MOUNT_BOOT"
sudo umount "$MOUNT_ROOT"
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

image_size_bytes=$(stat -c '%s' "$OUTPUT_IMAGE_PATH")
image_sha256=$(sha256sum "$OUTPUT_IMAGE_PATH" | awk '{print $1}')
config_sha256=$(sha256sum "$CONFIG_PATH" | awk '{print $1}')
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$MANIFEST_PATH" <<EOF
{
  "schemaVersion": 2,
  "applianceVersion": "$version",
  "builtAtUtc": "$built_at",
  "build": {
    "configSha256": "$config_sha256"
  },
  "content": {
    "profile": "$profile",
    "snapshot": "$snapshot"
  },
  "image": {
    "path": "$(basename "$OUTPUT_IMAGE_PATH")",
    "sizeBytes": $image_size_bytes,
    "sha256": "$image_sha256"
  },
  "storage": {
    "partitions": [
      { "name": "boot" },
      { "name": "root" },
      { "name": "zimdata" }
    ]
  },
  "runtime": {
    "serverMode": "native-kiwix-serve",
    "overlayRootEnabled": false,
    "zimDataOnDedicatedPartition": true,
    "docker": {
      "storageDriver": "none"
    }
  }
}
EOF

echo
echo "Appliance image build complete"
echo "Image:    $OUTPUT_IMAGE_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "SSID:     $ssid"
echo "Password: $password"
echo "Kiwix:    http://$ap_host:$ap_port"
