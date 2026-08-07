#!/usr/bin/env python3
"""Repository smoke validation for key architecture and docs guarantees."""

from __future__ import annotations

import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    compose_path = repo_root / "docker-compose.yml"
    env_example_path = repo_root / ".env.example"
    readme_path = repo_root / "README.md"
    estimate_md_path = repo_root / "docs" / "SPACE_ESTIMATE.md"
    estimate_json_path = repo_root / "docs" / "SPACE_ESTIMATE.json"

    compose = compose_path.read_text(encoding="utf-8")
    env_example = env_example_path.read_text(encoding="utf-8")
    readme = readme_path.read_text(encoding="utf-8")
    estimate_md = estimate_md_path.read_text(encoding="utf-8")
    estimate_json = json.loads(estimate_json_path.read_text(encoding="utf-8"))

    # Compose architecture checks.
    require("docker.sock" not in compose, "docker-compose.yml must not mount docker.sock")
    services = re.findall(r"^  ([A-Za-z0-9_.-]+):\s*$", compose, flags=re.MULTILINE)
    require(services == ["kiwix-server"], f"Expected exactly one service 'kiwix-server', got: {services}")

    # Default sync interval.
    require(
        re.search(r"^SYNC_INTERVAL_SECONDS=604800$", env_example, flags=re.MULTILINE) is not None,
        ".env.example must set SYNC_INTERVAL_SECONDS=604800",
    )

    # README consistency checks.
    require("<!-- SPACE_ESTIMATE:START -->" in readme, "README missing SPACE_ESTIMATE start marker")
    require("<!-- SPACE_ESTIMATE:END -->" in readme, "README missing SPACE_ESTIMATE end marker")
    require("one-service stack (`kiwix-server` only)" in readme, "README must describe one-service stack")
    require("Default is `604800` (weekly)." in readme, "README must state weekly default sync interval")
    require(
        "Uses torrent metadata when available (with a header-based fallback for non-torrent links)." in readme,
        "README must describe estimate probe method",
    )

    # Estimate completeness checks.
    unknown_count = estimate_json.get("unknown_count")
    require(isinstance(unknown_count, int), "docs/SPACE_ESTIMATE.json unknown_count must be an integer")
    require(unknown_count == 0, f"docs/SPACE_ESTIMATE.json unknown_count must be 0, got {unknown_count}")
    require(
        estimate_json.get("published_total_human") != "withheld (incomplete)",
        "docs/SPACE_ESTIMATE.json published_total_human must not be withheld",
    )
    require("Unknown sizes: `0`" in estimate_md, "docs/SPACE_ESTIMATE.md must report Unknown sizes: 0")

    print("Repository validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
