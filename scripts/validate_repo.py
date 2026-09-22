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
    appliance_doc_path = repo_root / "docs" / "APPLIANCE.md"
    appliance_config_path = repo_root / "config" / "appliance.example.json"
    build_image_ps1_path = repo_root / "scripts" / "build-appliance-image.ps1"
    build_image_sh_path = repo_root / "scripts" / "build-appliance-image.sh"
    create_sd_path = repo_root / "scripts" / "create-sd.ps1"
    estimate_md_path = repo_root / "docs" / "SPACE_ESTIMATE.md"
    estimate_json_path = repo_root / "docs" / "SPACE_ESTIMATE.json"

    compose = compose_path.read_text(encoding="utf-8")
    env_example = env_example_path.read_text(encoding="utf-8")
    readme = readme_path.read_text(encoding="utf-8")
    appliance_doc = appliance_doc_path.read_text(encoding="utf-8")
    appliance_config = json.loads(appliance_config_path.read_text(encoding="utf-8"))
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
    require("scripts/create-sd.ps1" in readme, "README must mention scripts/create-sd.ps1")
    require("scripts/build-appliance-image.ps1" in readme, "README must mention scripts/build-appliance-image.ps1")
    require(
        "Uses torrent metadata when available (with a header-based fallback for non-torrent links)." in readme,
        "README must describe estimate probe method",
    )

    # Appliance builder contract checks.
    require("No first-boot installation" in appliance_doc, "docs/APPLIANCE.md must define the offline appliance contract")
    require("scripts/create-sd.ps1" in appliance_doc, "docs/APPLIANCE.md must define create-sd.ps1 as the Windows entry point")
    require(isinstance(appliance_config.get("applianceVersion"), str), "config/appliance.example.json must set applianceVersion")
    require(appliance_config.get("content", {}).get("profile") == "medical-survival", "config/appliance.example.json must default to medical-survival profile")
    require(build_image_ps1_path.exists(), "scripts/build-appliance-image.ps1 must exist")
    require(build_image_sh_path.exists(), "scripts/build-appliance-image.sh must exist")
    require(create_sd_path.exists(), "scripts/create-sd.ps1 must exist")

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
