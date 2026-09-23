#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [[ -f .env ]]; then
  set -a
  . ./.env
  set +a
fi

: "${ZIM_DATA_DIR:=./zim_data}"
mkdir -p "$ZIM_DATA_DIR"

LIBRARY_FILE="$ZIM_DATA_DIR/library.xml"
TEMP_LIBRARY_FILE="$(mktemp "$ZIM_DATA_DIR/.library.xml.XXXXXX")"

cleanup() {
  rm -f "$TEMP_LIBRARY_FILE"
}
trap cleanup EXIT

for zim in "$ZIM_DATA_DIR"/*.zim; do
  [[ -f "$zim" ]] || continue
  if ! kiwix-manage "$TEMP_LIBRARY_FILE" add "$zim" 2>/dev/null; then
    echo "Failed to index ZIM file: $zim" >&2
    exit 1
  fi
done

mv -f "$TEMP_LIBRARY_FILE" "$LIBRARY_FILE"
trap - EXIT
