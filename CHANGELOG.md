# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

### Added
- Unattended SD preparation script for Windows (`scripts/prepare-sd-autoboot.ps1`) that writes first-boot automation to the Pi boot partition.
- Dedicated unattended setup guide (`AUTOBOOT_SD.md`) for zero-touch first boot.

### Changed
- Bootstrap logic now supports first-boot configuration injection via environment variables (content URL, sync interval, port, optional token file setup).

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
