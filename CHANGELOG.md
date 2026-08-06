# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

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
