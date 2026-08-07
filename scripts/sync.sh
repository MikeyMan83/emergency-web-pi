#!/usr/bin/env bash
set -euo pipefail

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

added=0

while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  fname="$(basename "${line%%.torrent}")"
  target="$ZIM_DATA_DIR/$fname"

  if [[ -f "$target" && -s "$target" ]]; then
    continue
  fi

  log "Downloading $fname"
  if ! aria2c \
    -c \
    --timeout=1800 \
    --max-tries=3 \
    --seed-time=0 \
    -d "$ZIM_DATA_DIR" \
    -o "$fname" \
    "$line"; then
    log "WARNING: $fname failed to download (dead torrent / no seeders?)"
    continue
  fi

  if [[ ! -s "$target" ]]; then
    log "WARNING: $fname is missing or zero bytes after download"
    continue
  fi

  size_a="$(stat -c%s "$target" 2>/dev/null || echo 0)"
  sleep 2
  size_b="$(stat -c%s "$target" 2>/dev/null || echo 0)"
  if [[ "$size_a" -le 0 || "$size_a" -ne "$size_b" ]]; then
    log "WARNING: $fname size is unstable ($size_a -> $size_b), skipping registration"
    continue
  fi

  log "Registering $fname"
  if docker compose exec -T "$COMPOSE_SERVICE" kiwix-manage /data/library.xml add "/data/$fname"; then
    added=$((added + 1))
  else
    log "WARNING: failed to register $fname in library.xml"
  fi
done < "$TMP_LIST"

log "Done. $added new ZIM(s) added."
