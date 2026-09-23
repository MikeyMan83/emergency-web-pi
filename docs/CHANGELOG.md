# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

## [0.1.51] - 2026-09-23

### Fixed
- Open selected library Learn More links through a validated HTTP(S) handler and show a visible error when Windows cannot launch the link.
- Put the content selection summary on its own row so it cannot overlap Select All or Select None.
- Validate Learn More links and wizard layout wiring in the repository checks.

## [0.1.50] - 2026-09-23

### Changed
- Applied a consistent visual hierarchy to the end-user wizard and Developer Tools, including styled primary and secondary actions.
- Surface Developer Tools prerequisite results directly in the Build tab and keep raw configuration collapsed by default.

### Fixed
- Keep direct Developer Tools image builds aligned with the normal wizard by automatically downloading the pinned, verified base image when no override is selected.

## [0.1.49] - 2026-09-23

### Fixed
- Rebuild `library.xml` atomically so a failed ZIM index leaves the previous valid library intact.
- Use the same base-plus-ZIMDATA partition capacity formula in the UI estimate that the dynamic builder uses.

### Tests
- Validate stable catalog source URLs and smoke-test the packaged frontend startup path on Windows CI.

## [0.1.48] - 2026-09-23

### Fixed
- Make direct Developer Tools image builds download and verify the pinned Raspberry Pi OS Lite base image when no local override is selected.

## [0.1.47] - 2026-09-23

### Fixed
- Calculate capacity from bundled verified catalog sizes instead of blocking the UI with per-library network probes.

## [0.1.46] - 2026-09-23

### Changed
- Replaced the former developer control dump with a tabbed Developer Tools workspace for Build, Content, SD & Output, and Diagnostics.
- Moved raw paths and configuration fields behind collapsible advanced sections while keeping direct testing and recovery controls available.

## [0.1.45] - 2026-09-23

### Fixed
- Start WinForms frontends in STA mode and record early initialization checkpoints before bundle discovery and wizard startup.

## [0.1.44] - 2026-09-23

### Fixed
- Allow the wizard `Disks` parameter to be empty so no-SD-card startup cannot fail during PowerShell parameter binding.

## [0.1.43] - 2026-09-23

### Fixed
- Normalize an empty removable-disk list before opening the wizard so it remains usable when no SD card is inserted.

## [0.1.42] - 2026-09-23

### Fixed
- Remove the fixed 90 GB writer rejection and enforce SD capacity from the exact final appliance image instead.

## [0.1.41] - 2026-09-23

### Added
- Inject an optional upstream NetworkManager Wi-Fi connection from the private appliance config for first-boot content installation.

### Fixed
- Remove the `wlan0` assumption from baked appliance and standalone access-point setup so NetworkManager can use the available Wi-Fi interface.

## [0.1.40] - 2026-09-23

### Fixed
- Keep portable caches, generated profiles, and temporary build output in the app-data workspace instead of the extracted release folder.
- Prevent library row selection from toggling checks, guard pre-handle UI updates, filter invalid zero-capacity disks, and widen wizard summaries to avoid clipped capacity text.

## [0.1.39] - 2026-09-23

### Tests
- Added a regression check requiring normal startup to invoke the wizard directly rather than depend on a simulated button click.

## [0.1.38] - 2026-09-23

### Fixed
- Start the wizard directly instead of simulating a button click during frontend startup.
- Simplified Windows release bundles to one root EXE and one root CMD launcher, eliminating duplicate entry points.

## [0.1.37] - 2026-09-23

### Fixed
- Keep the end-user wizard visible with a clear SD-card prompt when no writable card is detected instead of silently exiting.

## [0.1.36] - 2026-09-23

### Fixed
- Resolve the EXE launcher beside the physical executable instead of a temporary ps2exe directory, and keep CMD visible when startup fails.

## [0.1.35] - 2026-09-23

### Fixed
- Compile the EXE as a minimal launcher for the external frontend script and log before launching it, avoiding silent GUI-host startup failures.
- Add CMD launcher logging before PowerShell starts, so pre-frontend failures always leave a diagnostic record.

## [0.1.34] - 2026-09-23

### Added
- Added persistent per-launch frontend diagnostics under `%LOCALAPPDATA%\EmergencyWebPi` for startup and wizard failures.

## [0.1.33] - 2026-09-23

### Fixed
- Launch the end-user wizard as the visible startup dialog instead of making it a modal child of a transparent background form, preventing an accepted EXE from appearing to do nothing.

## [0.1.32] - 2026-09-23

### Fixed
- Make CMD launchers start the bundled PowerShell frontend directly instead of silently stopping when Windows SmartScreen blocks the unsigned EXE.

## [0.1.31] - 2026-09-23

### Changed
- Replaced the former legacy-screen fallback with an explicit Developer Tools workspace opened from the end-user wizard.

## [0.1.30] - 2026-09-23

### Fixed
- Start the normal app flow with only the end-user wizard and a dedicated build-progress dialog instead of displaying the legacy developer screen behind it.

## [0.1.29] - 2026-09-23

### Fixed
- Create release records as drafts and publish them only after the Windows ZIP and checksum upload successfully, preventing incomplete releases from appearing as latest.

## [0.1.28] - 2026-09-23

### Fixed
- Build the portable EXE with the same PowerShell host that runs packaging, allowing GitHub Actions to access its installed `ps2exe` module.

## [0.1.27] - 2026-09-23

### Added
- Added an on-device hardware acceptance command for first-boot, prebuilt, and finished-appliance checks.

### Tests
- Added CI shell syntax coverage for the hardware acceptance check and a regression guard against screenshot-capture blocking code.

## [0.1.26] - 2026-09-23

### Changed
- Open the same end-user wizard automatically from the EXE and CMD launch paths, leaving the underlying screen only as an advanced fallback.

## [0.1.25] - 2026-09-23

### Fixed
- Replaced raw catalog URLs in the main application window with friendly item names and sizes.
- Added a live content total and estimated minimum SD capacity to the visible catalog list.

## [0.1.24] - 2026-09-23

### Changed
- Made collection choices explain their purpose, included library count, and estimated storage before users fine-tune individual items.

## [0.1.23] - 2026-09-23

### Fixed
- Restored the complete Everything collection as the default wizard selection instead of the alphabetically first subset.
- Added validation that the default collection includes every catalog item.

## [0.1.22] - 2026-09-23

### Added
- Added a pinned, SHA-256-verified official Raspberry Pi OS Lite download manifest so the normal wizard no longer requires an operating-system image file.
- Added named Emergency & Medical, Essential Web, and Practical & Repair content collections with friendly descriptions, size estimates, and source links.

### Changed
- Made the normal wizard show live selection and SD capacity information, reject undersized cards, and explicitly identify the card that will be erased.

## [0.1.21] - 2026-09-23

### Fixed
- Made release publishing fail unless the Windows ZIP and checksum exist, then upload those assets explicitly to GitHub Releases.

### Docs
- Clarified that only prebuilt cards are immediately offline-ready; first-boot cards show status until selected content finishes installing.

## [0.1.20] - 2026-09-23

### Fixed
- Isolated the initial-content regression fixture from checkout-local runtime configuration so it runs consistently in CI.

## [0.1.19] - 2026-09-23

### Added
- Added recommended first-boot content installation alongside fully prebuilt offline cards, using the same ext4 appliance layout and runtime.
- Added resumable initial content installation with Pi status-page progress and retry behavior when temporary Internet is unavailable.

### Tests
- Added regression coverage for successful and interrupted initial content installation, plus status progress and readiness behavior.

## [0.1.18] - 2026-09-23

### Fixed
- Resolved the emergency AP password before image construction and bound SD writes to the matching resolved-config hash.
- Reworked dynamic SD creation to build one ext4 appliance image with selected content instead of adding an unused exFAT partition after flashing.
- Require the dedicated ZIM data mount before serving or syncing content, and prevent the status page from reporting ready until the content mount and library index are available.

### Docs
- Aligned the portable quick start, operations guide, and appliance contract with the local-base offline build workflow.

## [0.1.17] - 2026-09-23

### Changed
- Finalized Emergency Web Pi display branding in the Windows SD-card builder and appliance service descriptions while retaining compatible `pi-kiwix-*` service identifiers.

## [0.1.16] - 2026-09-23

### Docs
- Integrated the latest automated SD space estimate refresh after the Emergency Web Pi repo-slug release alignment.

## [0.1.15] - 2026-09-23

### Changed
- Updated source defaults, bootstrap URLs, release links, install paths, and related repo-slug references from `pi-kiwix-survival` to `emergency-web-pi`.

## [0.1.14] - 2026-09-23

### Fixed
- `scripts/package-portable.ps1` now bootstraps the NuGet provider and trusts PSGallery non-interactively before installing `ps2exe`, preventing packaging prompts on fresh Windows hosts.

## [0.1.13] - 2026-09-23

### Changed
- Renamed the Windows portable app branding and release artifacts from PiKiwixPortable to EmergencyWebPi.
- Simplified the portable Windows UI into a clearer 3-step flow with a safer SD-card picker and advanced settings hidden by default.
- Genericized remaining user-facing library/status wording while keeping internal runtime service compatibility intact.

## [0.1.12] - 2026-09-23

### Fixed
- Portable frontend path discovery now also probes the current process executable directory, improving reliability when launched elevated.
- Root launcher now starts `EmergencyWebPi.exe` directly when present before falling back to nested launch scripts.

## [0.1.11] - 2026-09-23

### Fixed
- Hardened portable frontend startup path discovery for EXE/script launches so bundled scripts resolve correctly across runtime contexts.
- Launchers now detect missing extracted files early and show clear "extract full ZIP first" guidance instead of cryptic file-not-found errors.
- Fixed elevated Windows launch edge cases where runtime path probing could fall back to temp/System32 and fail to find bundled scripts.

### Docs
- Aligned README quick-launch commands to EXE-first startup and explicit CMD debug fallback.
- Added explicit guidance to fully extract release ZIPs before launch and troubleshooting note for Temp-path missing-file errors.

## [0.1.10] - 2026-09-23

### Changed
- Portable release packaging is now EXE-first and fails if `EmergencyWebPi.exe` cannot be produced.
- Release bundles now include a root-level `EmergencyWebPi.exe` as the primary end-user entry point.
- README/HOWTO/RELEASE instructions now direct users to launch the root EXE rather than a CMD wrapper.

## [0.1.9] - 2026-09-23

### Fixed
- Fixed portable frontend startup when launched from bundled EXE paths where script-root detection could be empty and cause immediate path-binding errors.
- Fixed root and portable launchers to start the UI without leaving a black command window open.

### Changed
- Portable frontend now shows a clearer fatal error dialog for unhandled startup/runtime failures.

## [0.1.8] - 2026-09-23

### Added
- Added root-level launcher `Launch-EmergencyWebPi.cmd` so extracted bundles/source can be started without navigating subfolders.
- Added `scripts/package-portable.ps1` to build a release-ready Windows portable bundle and checksums.

### Changed
- `.github/workflows/release.yml` now builds and attaches `EmergencyWebPi-<version>-windows.zip` plus SHA256 checksums to GitHub releases.
- `portable/Launch-EmergencyWebPi.cmd` now prefers `EmergencyWebPi.exe` when available and falls back to PowerShell script.
- README/HOWTO/RELEASE docs now provide explicit end-user download artifact guidance and fallback path.

## [0.1.7] - 2026-09-23

### Docs
- Updated README practical recommendation to prioritize the Windows appliance image build-and-write flow, with first-boot automation positioned as development/recovery only.

### Added
- Added a portable Windows frontend (`portable/EmergencyWebPi.ps1` + `portable/Launch-EmergencyWebPi.cmd`) that wraps the existing safe build and SD-write scripts.
- Added `scripts/create-sd-dynamic.ps1` for dynamic Windows SD creation from a base image + profile list, including exFAT `ZIMDATA` partition creation and content download/copy.
- Added `scripts/rebuild-library.sh` shared helper for local library reconstruction.
- Added dynamic profile preset item picking in the portable frontend, allowing item-level selection before SD creation.
- Added preflight dynamic size estimation in the portable frontend before destructive write confirmation.
- Added an end-user wizard entry point in the portable frontend (`Start End-User Wizard`) to guide catalog selection and SD creation with minimal technical input.
- Added a Pi boot status web service (`pi-kiwix-status.service` + `scripts/status-web.py`) on port 80 to provide immediate first-boot readiness feedback.

### Changed
- `scripts/sync.sh` now refreshes `library.xml` from local ZIM files even when offline and reuses shared rebuild logic.
- `pi-kiwix-serve.service` now runs a pre-start library rebuild so copied content is indexed before serving.
- `scripts/create-sd-dynamic.ps1` can now auto-fetch latest base image + manifest from latest GitHub release assets via `-FetchLatestBase`.
- README and HOWTO now prioritize the end-user wizard workflow and mark manual/script-heavy paths as advanced/operator usage.
- Dynamic SD flow now supports configurable download location: preload on Windows or defer catalog download to Pi after first boot (`-SkipContentDownload`).
- `scripts/sync.sh` now supports local `zimlist.txt` mode via `ZIMDATA/.use_local_zimlist`, enabling deferred Pi-side catalog downloads.

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
