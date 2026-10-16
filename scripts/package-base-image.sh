#!/usr/bin/env bash
# Packages a base-mode image for GitHub release assets: gzip (native .NET can decompress it),
# split into parts when a file would exceed the per-asset limit, and record checksums in the manifest.
set -euo pipefail

usage() {
  echo "Usage: scripts/package-base-image.sh --image <img> --manifest <manifest.json> --out-dir <dir> [--version <release version>] [--max-asset-bytes <n>]" >&2
}

IMAGE=""
MANIFEST=""
OUT_DIR=""
RELEASE_VERSION=""
# GitHub's limit is 2 GiB per asset; stay below it.
MAX_ASSET_BYTES=$(( 1900 * 1024 * 1024 ))

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --version) RELEASE_VERSION="$2"; shift 2 ;;
    --max-asset-bytes) MAX_ASSET_BYTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$IMAGE" || -z "$MANIFEST" || -z "$OUT_DIR" ]]; then
  usage
  exit 1
fi
for cmd in jq gzip sha256sum split; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
[[ -f "$IMAGE" ]] || { echo "Image not found: $IMAGE" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

kind=$(jq -r '.kind // ""' "$MANIFEST")
if [[ "$kind" != "prebuilt-base" ]]; then
  echo "Manifest kind must be prebuilt-base (got '$kind'); build with --base-mode." >&2
  exit 1
fi

version="${RELEASE_VERSION:-$(jq -r '.applianceVersion' "$MANIFEST")}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
base_name="ewp-base-${version}"
gz_name="${base_name}.img.gz"
gz_path="$OUT_DIR/$gz_name"

# -n keeps the gzip stream free of file name/timestamp so rebuilds of identical input match.
gzip -9 -n -c "$IMAGE" > "$gz_path"
gz_sha256=$(sha256sum "$gz_path" | awk '{print $1}')
gz_size=$(stat -c '%s' "$gz_path")

parts_json='[]'
if (( gz_size > MAX_ASSET_BYTES )); then
  split -b "$MAX_ASSET_BYTES" -a 2 "$gz_path" "$OUT_DIR/${gz_name}.part-"
  rm -f "$gz_path"
  parts_json='[]'
  for part in "$OUT_DIR/${gz_name}.part-"*; do
    part_sha=$(sha256sum "$part" | awk '{print $1}')
    part_size=$(stat -c '%s' "$part")
    parts_json=$(jq -c --arg n "$(basename "$part")" --arg s "$part_sha" --argjson z "$part_size" \
      '. + [{name: $n, sizeBytes: $z, sha256: $s}]' <<<"$parts_json")
  done
fi

out_manifest="$OUT_DIR/${base_name}.img.manifest.json"
jq --arg v "$version" --arg n "$gz_name" --arg s "$gz_sha256" --argjson z "$gz_size" --argjson p "$parts_json" \
  '.releaseVersion = $v | .distribution = {compression: "gzip", file: $n, sizeBytes: $z, sha256: $s, parts: $p}' \
  "$MANIFEST" > "$out_manifest"

echo "Packaged: $out_manifest"
ls -l "$OUT_DIR"
