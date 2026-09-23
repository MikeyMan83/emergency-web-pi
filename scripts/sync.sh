#!/usr/bin/env bash
set -euo pipefail

# Ensure relative paths resolve correctly under systemd.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

: "${GITHUB_URL:?Set GITHUB_URL in .env}"
: "${ZIM_DATA_DIR:=./zim_data}"

mkdir -p "$ZIM_DATA_DIR"
LOG_FILE="$ZIM_DATA_DIR/sync.log"

log() {
  local message="[sync] $*"
  echo "$message"
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$message" >> "$LOG_FILE"
}

AUTH=()
if [[ -n "${GITHUB_TOKEN_FILE:-}" && -f "$GITHUB_TOKEN_FILE" ]]; then
  AUTH=(-H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")")
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

TMP_LIST="/tmp/zimlist.txt"
log "Fetching zimlist from $GITHUB_URL"
list_available=1
if ! curl -fsSL "${AUTH[@]}" "$GITHUB_URL" -o "$TMP_LIST"; then
  list_available=0
  log "Offline or unreachable - skipping download phase."
fi

processed=0

if [[ "$list_available" -eq 1 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    fname="$(basename "${line%%.torrent}")"
    target="$ZIM_DATA_DIR/$fname"

    log "Checking/Downloading $fname"
    if ! aria2c \
      -c \
      --timeout=1800 \
      --max-tries=3 \
      --seed-time=0 \
      -d "$ZIM_DATA_DIR" \
      -o "$fname" \
      "$line"; then
      log "WARNING: $fname failed to download or resume cleanly"
      continue
    fi

    if [[ ! -s "$target" ]]; then
      log "WARNING: $fname is missing or zero bytes after download"
      continue
    fi

    processed=$((processed + 1))
  done < "$TMP_LIST"
fi

log "Rebuilding library.xml from current ZIM files"
"$REPO_DIR/scripts/rebuild-library.sh"

if [[ "$list_available" -eq 1 ]]; then
  log "Done. Sync and registration complete. $processed item(s) validated/downloaded."
else
  log "Done. Library refresh complete using existing local ZIM files."
fi
