#!/usr/bin/env bash
set -euo pipefail

# Ensure docker compose and relative paths resolve correctly under systemd.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${GITHUB_URL:?Set GITHUB_URL in .env}"
: "${ZIM_DATA_DIR:=./zim_data}"
: "${COMPOSE_SERVICE:=kiwix-server}"

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
if ! curl -fsSL "${AUTH[@]}" "$GITHUB_URL" -o "$TMP_LIST"; then
  log "Offline or unreachable - leaving existing library untouched."
  exit 0
fi

processed=0

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

log "Rebuilding library.xml from current ZIM files"
docker compose exec -T "$COMPOSE_SERVICE" sh -c '
  : > /data/library.xml
  for zim in /data/*.zim; do
    [ -f "$zim" ] || continue
    if ! kiwix-manage /data/library.xml add "$zim" 2>/dev/null; then
      echo "[sync] WARNING: failed to register $zim" >&2
    fi
  done
'

log "Done. Sync and registration complete. $processed item(s) validated/downloaded."
