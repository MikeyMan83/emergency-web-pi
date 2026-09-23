#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FAKE_BIN="$TEMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/aria2c" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${ARIA2_FAIL:-0}" == "1" ]]; then
  exit 1
fi
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -d) target_dir="$2"; shift 2 ;;
    -o) output_name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$target_dir"
printf 'zim' > "$target_dir/$output_name"
EOF
chmod +x "$FAKE_BIN/aria2c"

cat > "$FAKE_BIN/kiwix-manage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'indexed\n' > "$1"
EOF
chmod +x "$FAKE_BIN/kiwix-manage"

run_initial_sync() {
  local data_dir="$1"
  PATH="$FAKE_BIN:$PATH" ZIM_DATA_DIR="$data_dir" "$REPO_ROOT/scripts/sync.sh" --initial
}

success_dir="$TEMP_DIR/success"
mkdir -p "$success_dir"
printf '%s\n' 'https://example.invalid/first.zim' 'https://example.invalid/second.zim' > "$success_dir/zimlist.txt"
touch "$success_dir/.use_local_zimlist" "$success_dir/.content-install-pending"
run_initial_sync "$success_dir"
test ! -e "$success_dir/.content-install-pending"
test -s "$success_dir/first.zim"
test -s "$success_dir/second.zim"
test -s "$success_dir/library.xml"

failure_dir="$TEMP_DIR/failure"
mkdir -p "$failure_dir"
printf '%s\n' 'https://example.invalid/retry.zim' > "$failure_dir/zimlist.txt"
touch "$failure_dir/.use_local_zimlist" "$failure_dir/.content-install-pending"
if ARIA2_FAIL=1 run_initial_sync "$failure_dir"; then
  echo "Initial sync unexpectedly succeeded after a failed download." >&2
  exit 1
fi
test -e "$failure_dir/.content-install-pending"
test ! -e "$failure_dir/retry.zim"