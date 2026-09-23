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
: > "$LIBRARY_FILE"

for zim in "$ZIM_DATA_DIR"/*.zim; do
  [[ -f "$zim" ]] || continue
  kiwix-manage "$LIBRARY_FILE" add "$zim" 2>/dev/null || true
done
