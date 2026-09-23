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

    env_example_path = repo_root / ".env.example"
    readme_path = repo_root / "README.md"
    appliance_doc_path = repo_root / "docs" / "APPLIANCE.md"
    appliance_config_path = repo_root / "config" / "appliance.example.json"
    build_image_ps1_path = repo_root / "scripts" / "build-appliance-image.ps1"
    build_image_sh_path = repo_root / "scripts" / "build-appliance-image.sh"
    create_sd_dynamic_path = repo_root / "scripts" / "create-sd-dynamic.ps1"
    config_resolver_path = repo_root / "scripts" / "resolve-appliance-config.ps1"
    rebuild_library_path = repo_root / "scripts" / "rebuild-library.sh"
    status_web_path = repo_root / "scripts" / "status-web.py"
    portable_ps1_path = repo_root / "portable" / "EmergencyWebPi.ps1"
    portable_cmd_path = repo_root / "portable" / "Launch-EmergencyWebPi.cmd"
    kiwix_service_path = repo_root / "scripts" / "systemd" / "pi-kiwix-serve.service"
    status_service_path = repo_root / "scripts" / "systemd" / "pi-kiwix-status.service"
    sync_service_path = repo_root / "scripts" / "systemd" / "pi-kiwix-sync.service"
    create_sd_path = repo_root / "scripts" / "create-sd.ps1"
    sync_path = repo_root / "scripts" / "sync.sh"
    estimate_md_path = repo_root / "docs" / "SPACE_ESTIMATE.md"
    initial_sync_service_path = repo_root / "scripts" / "systemd" / "pi-kiwix-initial-sync.service"
    estimate_json_path = repo_root / "docs" / "SPACE_ESTIMATE.json"

    env_example = env_example_path.read_text(encoding="utf-8")
    readme = readme_path.read_text(encoding="utf-8")
    appliance_doc = appliance_doc_path.read_text(encoding="utf-8")
    appliance_config = json.loads(appliance_config_path.read_text(encoding="utf-8"))
    estimate_md = estimate_md_path.read_text(encoding="utf-8")
    estimate_json = json.loads(estimate_json_path.read_text(encoding="utf-8"))
    create_sd = create_sd_path.read_text(encoding="utf-8")
    create_sd_dynamic = create_sd_dynamic_path.read_text(encoding="utf-8")
    status_web = status_web_path.read_text(encoding="utf-8")
    kiwix_service = kiwix_service_path.read_text(encoding="utf-8")
    sync_service = sync_service_path.read_text(encoding="utf-8")
    initial_sync_service = initial_sync_service_path.read_text(encoding="utf-8")
    sync_script = sync_path.read_text(encoding="utf-8")

    # Runtime architecture checks.
    require(kiwix_service_path.exists(), "scripts/systemd/pi-kiwix-serve.service must exist")
    require("COMPOSE_SERVICE=" not in env_example, ".env.example must not define COMPOSE_SERVICE")

    # Default sync interval.
    require(
        re.search(r"^SYNC_INTERVAL_SECONDS=604800$", env_example, flags=re.MULTILINE) is not None,
        ".env.example must set SYNC_INTERVAL_SECONDS=604800",
    )

    # README consistency checks.
    require("<!-- SPACE_ESTIMATE:START -->" in readme, "README missing SPACE_ESTIMATE start marker")
    require("<!-- SPACE_ESTIMATE:END -->" in readme, "README missing SPACE_ESTIMATE end marker")
    require("pi-kiwix-serve.service" in readme, "README must mention pi-kiwix-serve.service")
    require("Default is `604800` (weekly)." in readme, "README must state weekly default sync interval")
    require("scripts/create-sd.ps1" in readme, "README must mention scripts/create-sd.ps1")
    require("scripts/create-sd-dynamic.ps1" in readme, "README must mention scripts/create-sd-dynamic.ps1")
    require("scripts/build-appliance-image.ps1" in readme, "README must mention scripts/build-appliance-image.ps1")
    require("portable/Launch-EmergencyWebPi.cmd" in readme, "README must mention portable launcher")
    require("pi-kiwix-status.service" in readme, "README must mention pi-kiwix-status.service")
    require(
        "Uses torrent metadata when available (with a header-based fallback for non-torrent links)." in readme,
        "README must describe estimate probe method",
    )

    # Appliance builder contract checks.
    require("Prebuilt mode requires no first-boot Internet" in appliance_doc, "docs/APPLIANCE.md must define the prebuilt offline contract")
    require("first-boot mode requires temporary Internet" in appliance_doc, "docs/APPLIANCE.md must define the first-boot content contract")
    require("scripts/create-sd.ps1" in appliance_doc, "docs/APPLIANCE.md must define create-sd.ps1 as the Windows entry point")
    require(isinstance(appliance_config.get("applianceVersion"), str), "config/appliance.example.json must set applianceVersion")
    require(appliance_config.get("content", {}).get("profile") == "medical-survival", "config/appliance.example.json must default to medical-survival profile")
    require(appliance_config.get("network", {}).get("ap", {}).get("countryCode") == "NL", "config/appliance.example.json must set network.ap.countryCode to NL by default")
    require(build_image_ps1_path.exists(), "scripts/build-appliance-image.ps1 must exist")
    require(build_image_sh_path.exists(), "scripts/build-appliance-image.sh must exist")
    require(create_sd_dynamic_path.exists(), "scripts/create-sd-dynamic.ps1 must exist")
    require(config_resolver_path.exists(), "scripts/resolve-appliance-config.ps1 must exist")
    require(rebuild_library_path.exists(), "scripts/rebuild-library.sh must exist")
    require(status_web_path.exists(), "scripts/status-web.py must exist")
    require(portable_ps1_path.exists(), "portable/EmergencyWebPi.ps1 must exist")
    require(portable_cmd_path.exists(), "portable/Launch-EmergencyWebPi.cmd must exist")
    require(status_service_path.exists(), "scripts/systemd/pi-kiwix-status.service must exist")
    require(create_sd_path.exists(), "scripts/create-sd.ps1 must exist")
    require(sync_path.exists(), "scripts/sync.sh must exist")
    require(initial_sync_service_path.exists(), "scripts/systemd/pi-kiwix-initial-sync.service must exist")
    require("Manifest.build.configSha256" in create_sd, "create-sd.ps1 must verify the resolved config hash")
    require("network.ap.password is a placeholder" in create_sd, "create-sd.ps1 must reject placeholder AP passwords")
    require("build-appliance-image.ps1" in create_sd_dynamic, "dynamic builder must build the appliance image before flashing")
    require('string]$ContentMode = "FirstBoot"' in create_sd_dynamic, "dynamic builder must default to first-boot content installation")
    require('"Prebuilt"' in create_sd_dynamic, "dynamic builder must support fully prebuilt content")
    require(".content-install-pending" in create_sd_dynamic, "dynamic builder must mark first-boot content installation")
    require("New-ZimDataPartition" not in create_sd_dynamic, "dynamic builder must not create a separate exFAT content partition")
    require("Format-Volume" not in create_sd_dynamic, "dynamic builder must not format an exFAT content partition")
    require("RequiresMountsFor=/var/lib/pi-kiwix-zimdata" in kiwix_service, "kiwix service must require the ZIM data mount")
    require("RequiresMountsFor=/var/lib/pi-kiwix-zimdata" in sync_service, "sync service must require the ZIM data mount")
    require("ConditionPathExists=/var/lib/pi-kiwix-zimdata/.content-install-pending" in initial_sync_service, "initial sync service must run only while content installation is pending")
    require("scripts/sync.sh --initial" in initial_sync_service, "initial sync service must use initial completion semantics")
    require("Initial content installation complete" in sync_script, "sync script must complete first-boot content installation")
    require('"ready": kiwix_active and zim_data_mounted' in status_web, "status page must require mounted content before ready")

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
