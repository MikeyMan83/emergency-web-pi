#!/usr/bin/env python3
"""Serve a lightweight local boot/status page for appliance users."""

from __future__ import annotations

import argparse
import http.server
import json
import os
import pathlib
import socketserver
import subprocess
import time
from datetime import datetime, timezone


def parse_env_file(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def service_active(name: str) -> bool:
    result = subprocess.run(
        ["systemctl", "is-active", name],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout.strip() == "active"


def safe_tail(path: pathlib.Path) -> str:
    if not path.exists():
        return "No sync log yet"
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        if not lines:
            return "Sync log is empty"
        return lines[-1]
    except OSError:
        return "Unable to read sync log"


def count_profile_entries(path: pathlib.Path) -> int:
    try:
        return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#"))
    except OSError:
        return 0


def content_storage_mounted(path: pathlib.Path) -> bool:
    try:
        return path.is_mount()
    except (AttributeError, NotImplementedError):
        return False


def build_page(status: dict[str, object], kiwix_port: int) -> str:
    ready = "true" if status["ready"] else "false"
    message = "Library is ready" if status["ready"] else "Preparing content. Keep power connected."
    return f"""<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>Emergency Web Pi Status</title>
<style>
  body {{ font-family: 'Segoe UI', sans-serif; margin: 0; background: #f7f4ed; color: #1f2a37; }}
  .wrap {{ max-width: 760px; margin: 0 auto; padding: 28px; }}
  .card {{ background: #fff; border: 1px solid #d8d2c4; border-radius: 14px; padding: 20px; }}
  .headline {{ font-size: 28px; margin: 0 0 10px; }}
  .state {{ font-size: 18px; margin: 6px 0 16px; color: #7a5f19; }}
  .ok {{ color: #1f7a1f; }}
  .row {{ margin: 6px 0; }}
  .spinner {{ width: 18px; height: 18px; border: 3px solid #e0d5bd; border-top-color: #b58500; border-radius: 50%; display: inline-block; animation: spin 1s linear infinite; margin-right: 8px; vertical-align: middle; }}
  .hidden {{ display: none; }}
  .btn {{ display: inline-block; margin-top: 14px; padding: 10px 14px; border-radius: 8px; text-decoration: none; background: #0b5cab; color: #fff; }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
</style>
</head>
<body>
  <div class=\"wrap\">
    <div class=\"card\">
            <h1 class=\"headline\">Emergency Web Pi</h1>
      <div id=\"state\" class=\"state\"><span id=\"spin\" class=\"spinner\"></span>{message}</div>
            <div class=\"row\">Library service: <strong id=\"kiwix\">{status['kiwixActive']}</strong></div>
      <div class=\"row\">Sync service active: <strong id=\"sync\">{status['syncActive']}</strong></div>
      <div class=\"row\">Local ZIM files: <strong id=\"zimCount\">{status['zimCount']}</strong></div>
      <div class=\"row\">Last sync log: <strong id=\"last\">{status['lastSyncLine']}</strong></div>
      <a id=\"open\" class=\"btn hidden\" href=\"http://10.42.0.1:{kiwix_port}\">Open Library</a>
      <div class=\"row\" style=\"margin-top:12px;color:#666;\">Status refreshes automatically every 3 seconds.</div>
    </div>
  </div>
<script>
async function refresh() {{
  try {{
    const r = await fetch('/status.json?_=' + Date.now());
    const s = await r.json();
    document.getElementById('kiwix').textContent = s.kiwixActive ? 'Ready' : 'Starting';
    document.getElementById('sync').textContent = s.syncActive ? 'Running' : 'Idle';
    document.getElementById('zimCount').textContent = s.zimCount;
    document.getElementById('last').textContent = s.lastSyncLine;

    const state = document.getElementById('state');
    const spin = document.getElementById('spin');
    const open = document.getElementById('open');
        if (s.ready) {{
      state.classList.add('ok');
            state.textContent = 'Library is ready.';
      spin.classList.add('hidden');
      open.classList.remove('hidden');
    }} else {{
      state.classList.remove('ok');
        state.textContent = !s.zimDataMounted ? 'Content storage is unavailable.' : (s.contentInstallPending ? 'Downloading library content: ' + s.zimCount + '/' + s.expectedZimCount + ' files (' + s.contentProgressPercent + '%).' : 'Preparing content. Keep power connected.');
      spin.classList.remove('hidden');
      open.classList.add('hidden');
    }}
  }} catch (e) {{
  }}
}}
refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>
"""


class StatusHandler(http.server.BaseHTTPRequestHandler):
    repo_root: pathlib.Path
    zim_data_dir: pathlib.Path
    kiwix_port: int

    def _status(self) -> dict[str, object]:
        sync_log = self.zim_data_dir / "sync.log"
        zim_count = len(list(self.zim_data_dir.glob("*.zim"))) if self.zim_data_dir.exists() else 0
        library_file = self.zim_data_dir / "library.xml"
        pending_marker = self.zim_data_dir / ".content-install-pending"
        expected_zim_count = count_profile_entries(self.zim_data_dir / "zimlist.txt")
        zim_data_mounted = content_storage_mounted(self.zim_data_dir)
        library_indexed = library_file.exists() and library_file.stat().st_size > 0
        kiwix_active = service_active("pi-kiwix-serve.service")
        initial_sync_active = service_active("pi-kiwix-initial-sync.service")
        content_install_pending = pending_marker.exists()
        content_progress_percent = min(100, int((zim_count * 100) / expected_zim_count)) if expected_zim_count else 0
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "uptimeSeconds": int(time.time()),
            "kiwixActive": kiwix_active,
            "syncActive": service_active("pi-kiwix-sync.service") or initial_sync_active,
            "initialSyncActive": initial_sync_active,
            "zimDataMounted": zim_data_mounted,
            "libraryIndexed": library_indexed,
            "contentInstallPending": content_install_pending,
            "expectedZimCount": expected_zim_count,
            "contentProgressPercent": content_progress_percent,
            "ready": kiwix_active and zim_data_mounted and not content_install_pending and zim_count > 0 and library_indexed,
            "zimCount": zim_count,
            "lastSyncLine": safe_tail(sync_log),
        }

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/status.json"):
            payload = self._status()
            data = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if self.path == "/" or self.path.startswith("/?"):
            payload = self._status()
            body = build_page(payload, self.kiwix_port).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=80)
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo).resolve()
    env_data = parse_env_file(repo_root / ".env")
    zim_data_raw = env_data.get("ZIM_DATA_DIR", "./zim_data")
    kiwix_port = int(env_data.get("KIWIX_PORT", "8080"))

    if os.path.isabs(zim_data_raw):
        zim_data_dir = pathlib.Path(zim_data_raw)
    else:
        zim_data_dir = (repo_root / zim_data_raw).resolve()

    class BoundStatusHandler(StatusHandler):
        pass

    BoundStatusHandler.repo_root = repo_root
    BoundStatusHandler.zim_data_dir = zim_data_dir
    BoundStatusHandler.kiwix_port = kiwix_port

    with socketserver.TCPServer((args.host, args.port), BoundStatusHandler) as server:
        server.serve_forever()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
