#!/usr/bin/env bash
set -euo pipefail

# Ensure relative paths resolve correctly under systemd.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

INITIAL_INSTALL=0
if [[ "${1:-}" == "--initial" ]]; then
  INITIAL_INSTALL=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--initial]" >&2
  exit 2
fi

: "${GITHUB_URL:=}"
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
list_available=1
local_list_path="$ZIM_DATA_DIR/zimlist.txt"
local_mode_marker="$ZIM_DATA_DIR/.use_local_zimlist"
pending_marker="$ZIM_DATA_DIR/.content-install-pending"

if [[ -f "$local_mode_marker" && -s "$local_list_path" ]]; then
  cp "$local_list_path" "$TMP_LIST"
  log "Using local zimlist from $local_list_path"
else
  if [[ -n "${GITHUB_URL:-}" ]]; then
    log "Fetching zimlist from $GITHUB_URL"
    if ! curl -fsSL "${AUTH[@]}" "$GITHUB_URL" -o "$TMP_LIST"; then
      if [[ -s "$local_list_path" ]]; then
        cp "$local_list_path" "$TMP_LIST"
        log "Remote list unavailable - falling back to local zimlist at $local_list_path"
      else
        list_available=0
        log "Offline or unreachable - skipping download phase."
      fi
    fi
  elif [[ -s "$local_list_path" ]]; then
    cp "$local_list_path" "$TMP_LIST"
    log "GITHUB_URL not set - using local zimlist at $local_list_path"
  else
    list_available=0
    log "No list source configured - skipping download phase."
  fi
fi

processed=0
expected=0
failed=0

if [[ "$list_available" -eq 1 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    expected=$((expected + 1))
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
      failed=$((failed + 1))
      continue
    fi

    if [[ ! -s "$target" ]]; then
      log "WARNING: $fname is missing or zero bytes after download"
      failed=$((failed + 1))
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

if [[ "$INITIAL_INSTALL" -eq 1 ]]; then
  if [[ "$list_available" -eq 1 && "$expected" -gt 0 && "$failed" -eq 0 && "$processed" -eq "$expected" ]]; then
    rm -f "$pending_marker"
    log "Initial content installation complete."
  else
    log "Initial content installation remains pending ($processed/$expected complete); retrying when internet is available."
    exit 1
  fi
fi
