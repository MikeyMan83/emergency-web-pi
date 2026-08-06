#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

if [ -z "${GITHUB_URL:-}" ]; then
  log "ERROR: GITHUB_URL is not set."
  exit 1
fi

case "${SYNC_INTERVAL_SECONDS:-86400}" in
  ''|*[!0-9]*)
    log "WARN: SYNC_INTERVAL_SECONDS is invalid, defaulting to 86400."
    SYNC_INTERVAL_SECONDS=86400
    ;;
  *) ;;
esac

case "${ARIA2_MAX_CONCURRENT_DOWNLOADS:-3}" in
  ''|*[!0-9]*)
    log "WARN: ARIA2_MAX_CONCURRENT_DOWNLOADS is invalid, defaulting to 3."
    ARIA2_MAX_CONCURRENT_DOWNLOADS=3
    ;;
  *) ;;
esac

apk add --no-cache aria2 curl docker-cli >/dev/null

TMP_FILE="/data/zimlist.new"
NORMALIZED_FILE="/data/zimlist.normalized"
TARGET_FILE="/data/zimlist.txt"
CURL_CONFIG_FILE="/tmp/curl.conf"

cleanup() {
  rm -f "${TMP_FILE}" "${NORMALIZED_FILE}" "${CURL_CONFIG_FILE}"
}

trap cleanup EXIT

resolve_token() {
  if [ -n "${GITHUB_TOKEN_FILE:-}" ] && [ -r "${GITHUB_TOKEN_FILE}" ]; then
    TOKEN="$(tr -d '\r\n' < "${GITHUB_TOKEN_FILE}")"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    TOKEN="${GITHUB_TOKEN}"
  else
    TOKEN=""
  fi
}

download_list() {
  resolve_token

  if [ -n "${TOKEN}" ]; then
    {
      printf 'silent\n'
      printf 'show-error\n'
      printf 'fail\n'
      printf 'location\n'
      printf 'output = "%s"\n' "${TMP_FILE}"
      printf 'header = "Authorization: Bearer %s"\n' "${TOKEN}"
      printf 'url = "%s"\n' "${GITHUB_URL}"
    } > "${CURL_CONFIG_FILE}"
    curl -K "${CURL_CONFIG_FILE}"
  else
    curl -fsSL "${GITHUB_URL}" -o "${TMP_FILE}"
  fi
}

while true; do
  log "Checking GitHub for updates..."

  if ! download_list; then
    log "WARN: Could not download zim list. Retrying after sleep interval."
    sleep "${SYNC_INTERVAL_SECONDS}"
    continue
  fi

  # Normalize line endings to avoid false diffs from Windows CRLF.
  tr -d '\r' < "${TMP_FILE}" > "${NORMALIZED_FILE}"

  if [ ! -s "${NORMALIZED_FILE}" ]; then
    log "WARN: Downloaded list is empty. Ignoring update."
    rm -f "${TMP_FILE}" "${NORMALIZED_FILE}" "${CURL_CONFIG_FILE}"
    sleep "${SYNC_INTERVAL_SECONDS}"
    continue
  fi

  if [ ! -f "${TARGET_FILE}" ] || ! cmp -s "${TARGET_FILE}" "${NORMALIZED_FILE}"; then
    log "New content detected. Syncing torrents."

    if aria2c \
      --seed-time=0 \
      --continue=true \
      --input-file="${NORMALIZED_FILE}" \
      --dir=/data \
      --max-concurrent-downloads="${ARIA2_MAX_CONCURRENT_DOWNLOADS}"; then
      mv "${NORMALIZED_FILE}" "${TARGET_FILE}"
      log "Torrent sync complete. Restarting kiwix-server."
      if ! docker restart kiwix-server >/dev/null; then
        log "WARN: Failed to restart kiwix-server."
      fi
    else
      log "WARN: aria2 sync failed. Will retry on next cycle."
    fi
  else
    log "No changes detected."
  fi

  rm -f "${TMP_FILE}" "${NORMALIZED_FILE}" "${CURL_CONFIG_FILE}"
  sleep "${SYNC_INTERVAL_SECONDS}"
done
