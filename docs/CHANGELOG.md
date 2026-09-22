# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

### Docs
- Updated README practical recommendation to prioritize the Windows appliance image build-and-write flow, with first-boot automation positioned as development/recovery only.

### Added
- Added a portable Windows frontend (`portable/PiKiwixPortable.ps1` + `portable/Launch-PiKiwixPortable.cmd`) that wraps the existing safe build and SD-write scripts.

## [0.1.6] - 2026-09-22

### Changed
- `scripts/setup-ap.sh` now provisions standalone AP mode through NetworkManager (`nmcli`) shared mode instead of `dhcpcd` + `hostapd` + external `dnsmasq`, preventing failures on modern Raspberry Pi OS Bookworm defaults.
- `scripts/setup-ap.sh` now installs a captive-portal DNS sinkhole (`address=/#/<AP_IP>`) for offline AP mode so mobile clients remain on the network and resolve local browsing reliably.
- Runtime stack now uses native `kiwix-serve` systemd service (`pi-kiwix-serve.service`) instead of Docker/Compose, reducing dependencies and avoiding overlayfs container storage conflicts.
- `scripts/install.sh`, `scripts/bootstrap-pi.sh`, `scripts/sync.sh`, and `scripts/enable-readonly.sh` now operate on the native runtime path.
- Removed `docker-compose.yml` from the active appliance runtime.

### Added
- Added `scripts/build-appliance-image.sh` to build a bootable appliance image from Raspberry Pi OS Lite, create a dedicated `zimdata` partition, preconfigure AP/network/systemd services, and emit a manifest consumed by `scripts/create-sd.ps1`.
- Added `scripts/build-appliance-image.ps1` as a Windows WSL wrapper so image build and SD write can run in one Windows-led workflow.

### Docs
- Updated AP setup guidance to describe NetworkManager hotspot behavior and captive DNS handling.
- Added explicit Windows end-to-end appliance build and write flow documentation.
- Updated operations/setup documentation for native `kiwix-serve` service management.

## [0.1.5] - 2026-09-22

### Changed
- `scripts/sync.sh` now always lets `aria2c -c` evaluate existing files so interrupted downloads reliably resume instead of being skipped.
- `scripts/sync.sh` now rebuilds `library.xml` from on-disk `.zim` files after sync, preventing orphaned libraries after power loss between download and registration.
- `scripts/sync.sh` now forces repository-root execution context so relative paths and `docker compose` behave consistently under systemd.
- `scripts/create-sd.ps1` now requires and validates an image manifest with SHA256, dedicated `zimdata` partition declaration, and overlay/docker safety checks before writing SD media.

### Docs
- Added explicit appliance image manifest requirements and runtime invariants for the Windows builder flow.

## [0.1.4] - 2026-09-22

### Changed
- `scripts/create-sd.ps1` now auto-generates an emergency AP password when config uses placeholder values and writes the resolved private config to `config/appliance.local.json`.
- `scripts/create-sd.ps1` now writes a provided appliance image directly to the selected physical disk with `-Force` and verifies the written image prefix hash.
- `scripts/create-sd.ps1` now auto-discovers appliance images from common local artifact paths when `-ImagePath` is omitted.
- `config/appliance.example.json` now uses `__GENERATE__` for AP password instead of a reusable static example password.

### Docs
- Simplified appliance-builder wording to keep implementation details out of user-facing contract language.

## [0.1.3] - 2026-09-22

### Added
- Optional zero-touch AP enablement through first-boot automation via `BOOTSTRAP_ENABLE_AP` and `scripts/prepare-sd-autoboot.ps1 -EnableAp`.
- Added first-class appliance builder contract documentation and a Windows `scripts/create-sd.ps1` entry point.

### Changed
- `docker-compose.yml` now mounts Kiwix content from configurable `ZIM_DATA_DIR` with a safe default.
- `scripts/setup-ap.sh` now uses configurable `AP_COUNTRY_CODE` and validates it before writing `hostapd` configuration.
- `scripts/enable-readonly.sh` now migrates `zim_data` to separate persistent storage before enabling overlayfs, preventing content loss on reboot.

### Docs
- Clarified the zero-touch SD-card workflow and standalone AP behavior in the primary setup and operations docs.
- Repositioned the first-boot path as development/recovery while documenting the finished offline-appliance target.

## [0.1.2] - 2026-08-07

### Changed
- Refactored architecture to a single `kiwix-server` container using `--monitorLibrary` for auto-reload.
- Removed Docker socket dependency and sidecar polling container.
- Moved content sync to host-level weekly systemd timer (`pi-kiwix-sync.timer`).
- Added one-command installer (`scripts/install.sh`) and AP/read-only helper scripts.
- Consolidated setup docs into the top-level README quickstart.
- Updated sync/docs wording to support both torrent and direct `.zim` content URLs.

### Added
- Added repository smoke validator (`scripts/validate_repo.py`) and wired it into CI.

### Docs
- Reworked PR template confirmations to avoid persistent unchecked task boxes while preserving required review checks.

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
