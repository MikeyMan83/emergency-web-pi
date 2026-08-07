# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

### Changed
- Refactored architecture to a single `kiwix-server` container using `--monitorLibrary` for auto-reload.
- Removed Docker socket dependency and sidecar polling container.
- Moved content sync to host-level weekly systemd timer (`pi-kiwix-sync.timer`).
- Added one-command installer (`scripts/install.sh`) and AP/read-only helper scripts.
- Consolidated setup docs into the top-level README quickstart.

## [0.1.1] - 2026-08-06

### Added
- Unattended SD preparation script for Windows (`scripts/prepare-sd-autoboot.ps1`) that writes first-boot automation to the Pi boot partition.
- Dedicated unattended setup guide (`AUTOBOOT_SD.md`) for zero-touch first boot.
- Realtime SD space estimate automation on GitHub via `.github/workflows/space-estimate.yml` and `scripts/estimate_space.py`.
- Machine-readable estimate artifact (`SPACE_ESTIMATE.json`) for tooling and dashboards.

### Changed
- Bootstrap logic now supports first-boot configuration injection via environment variables (content URL, sync interval, port, optional token file setup).
- Simplified primary setup docs to default to Raspberry Pi Imager + one-command SSH deployment, with boot-partition scripting moved to advanced optional guidance.
- Set default bootstrap and docs URLs to `MikeyMan83/pi-kiwix-survival` for copy-paste-ready deployment.
- Documented explicit offline-first behavior in primary setup docs.
- Simplified primary setup again to a zero-touch `firstrun.sh` boot-partition flow (flash, paste, boot) with SSH deploy retained as fallback only.
- Space estimate workflow now refreshes a top-level README status block with current known required size and recommended SD target.
- Space estimate report now includes readable library names and explicit warning lines when totals are partial or unresolved.
- Space estimate publishing now withholds totals when any item size is unresolved, to avoid sharing misleading SD-size numbers.
- README now includes an explicit current-profile inventory and highlights high-overhead content.

## [0.1.0] - 2026-08-06

### Added
- Two-container stack (`kiwix-server` + `kiwix-sync-agent`) for offline Kiwix serving and Git-based sync.
- Sync sidecar script with:
  - periodic GitHub polling,
  - CRLF normalization,
  - resumable torrent downloads via `aria2c`,
  - container restart after successful content sync.
- Token-file support (`GITHUB_TOKEN_FILE`) with fallback to `GITHUB_TOKEN`.
- RPi 3B+ quickstart guidance for SD card flashing and first boot automation.
- First-boot bootstrap script to install Docker, clone/pull repo, and launch the stack.
- Curated medical-survival content profile.
