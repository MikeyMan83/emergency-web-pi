# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

## [0.4.1] - 2026-10-21

### Fixed

- The creator no longer hangs on "Checking requirements" with a blank details panel. The build-output pump read the child process streams before starting the process, so the build never launched and progress stopped silently; the pump now starts the process first and streams stdout and stderr on the UI dispatcher, forwarding every writer line to the details log and status line.
- The SD writer now reports each requirement check, the base-image lookup/download/verification (with real byte progress and network timeouts), unpack progress, and write progress, so the progress view reflects the actual work instead of sitting silent during long operations.
- Cancelling a build now stops the whole writer process tree (including download helpers) and is disabled while it is not safe; a stall indicator appears when an operation reports no progress for several minutes.

## [0.4.0] - 2026-10-21

### Changed

- The portable Windows app was rebuilt as a modern WPF creator. It opens directly into a four-step guided flow (Content, Installation, SD card, Review) followed by a dedicated progress view and a success screen with first-boot instructions and the printable Wi-Fi label.
- Content profiles are presented as cards with descriptions, download sizes, library counts, and category tags. The recommended profile stays preselected, and an optional **Customize content** view lists every library with its description, size, and Learn more link.
- The installation step explains the two modes in plain language (**Prepare everything now** / **Download content on first boot**) without exposing internal mode names.
- Removable drives are shown as selectable cards with model, capacity, drive letters, and a clear Ready / Too small / Not removable status. The selected card is revalidated immediately before writing, and the capacity indicator compares the card against the real required size. Unknown sizes are reported as "cannot be estimated" instead of being treated as zero.
- Progress is mapped from the actual writer output to human-readable stages (checking requirements, preparing system files, downloading content, writing the appliance, preparing the partition, copying the library, verifying, finished), with live download percentages, a safe-cancel window before the destructive write, and technical logs behind **Show details**. Errors state what failed in plain language and what to do next.
- Developer Tools is now a separate tabbed window (Build, Content, SD & Output, Diagnostics, Advanced) opened from the creator window. It keeps every existing developer capability.
- The shared creator logic moved to `portable/EmergencyWebPi-Core.ps1` (catalog and profile loading, capacity formula, disk classification, stage mapping, frozen writer arguments, Wi-Fi credentials and label), covered by a new PowerShell test suite that also runs in CI.

### Removed

- The legacy WinForms wizard frontend was replaced by the WPF creator; no supported workflow depended on it.

### Fixed

- The UI no longer blocks while streaming build output: child-process output is pumped on a dispatcher timer instead of blocking reads.
- The **Customize content** expander header now renders, so the selected library total is always visible and updates as selections change.
- Profile sorting, the **Recommended** badge, and the recommended-profile preselection now work: profile file names carry a `-zimlist` suffix that previously defeated the name match.
- Unchecking every library now disables **Continue** and the review summary reports exactly the libraries that will be built, instead of silently falling back to the full profile.
- The **Learn more** link in the library list uses the correct WPF hyperlink type, and the link style is applied to the link itself.

### Notes

- The planned Tauri 2 rewrite (docs/V2_TAURI_PLAN.md) was not adopted for this release: the app ships as WPF, which is built into Windows 10/11 and needs no extra runtime. See docs/V2_TAURI_PLAN.md for the status.

## [0.3.4] - 2026-10-20

### Fixed

- The progress window stays responsive during the build; the last lines of the SD build output are shown live in the window instead of freezing it.

### Removed

- The non-functional home Wi-Fi first-boot option was removed from the wizard (first-boot downloads need Ethernet).

### Changed

- Internal rename of the dynamic build argument list (`$args` to `$buildArgs`).

## [0.3.3] - 2026-10-16

### Fixed

- Clicking "Estimate + Build" could end the app with no message. The build now starts directly from the wizard instead of through a simulated button click, and any failure is reported in a window.
- The app no longer exits silently: if the setup window closes unexpectedly it explains why and points to the diagnostic log.

### Changed

- Logs now live in a `logs` folder next to the app (falling back to AppData when that folder is not writable). Only the 10 newest startup logs are kept, and Developer Tools has an "Open logs" button.

## [0.3.2] - 2026-10-16

### Fixed

- The wizard exited after clicking "Estimate + Build" because the selected libraries were handed to the SD writer as empty entries. Selections are now passed correctly.
- The wizard now reopens instead of quitting when a recoverable problem occurs (preflight failure, SD card too small, erase declined, or a failed build).

## [0.3.1] - 2026-10-16

### Changed

- The Release workflow now builds and attaches the base image automatically; the Image Build tag trigger was removed (manual dispatch remains for one-off builds).

### Fixed

- Image Build base-mode failure: the 768 MiB rootfs headroom regrow asked for more blocks than the partition held (876,544 available vs 976,171 requested). The base build now grows the root partition by 2 GiB, and the regrow validates the parsed ext4 geometry and caps at the partition size with a clear message.
- Wizard "Estimate + Build" closed the app without building: the wizard selection was stored in a handler-local variable and discarded, so the wizard looked cancelled.

## [0.3.0] - 2026-10-16

### Added

- `scripts/create-sd-prebuilt.ps1`: native Windows SD writer. It verifies the base image (schemaVersion 3 manifest, SHA-256), raw-writes it, creates an exFAT `ZIMDATA` partition, copies the content downloaded with the bundled aria2c, and writes `device-config.json`, `content-manifest.json` and `.content-complete`. No WSL needed.
- The end-user wizard now uses the prebuilt writer, with per-card generated Wi-Fi credentials, automatic base-image download from the release (token via `GITHUB_TOKEN`/`gh` for private repos) and a manual-file fallback. The WSL check moved to Developer Tools, where it still guards the dynamic builder.
- `build-appliance-image.sh --base-mode` builds a shared, credential-free base image (boot + shrunk root, no zimdata partition) with a new `prebuilt-base` manifest (schemaVersion 3).
- `scripts/package-base-image.sh` and the `image-build.yml` workflow gzip, split (if over the asset limit) and checksum the base image. Existing builder paths are unchanged.
- Base images mount `LABEL=ZIMDATA` as kernel exFAT with the service account's uid/gid and `umask=022`, and ship `pi-kiwix-device-config.service`: it applies per-card Wi-Fi credentials from `device-config.json` (then deletes it) or generates a password and writes `wifi-credentials.txt`.
- `sync.sh --initial` treats `.content-complete` plus a valid `content-manifest.json` as fulfilled content (no network), and `hardware-acceptance.sh --prebuilt` checks exFAT mount, uid/gid options, plaintext removal and manifest items on exFAT cards.
- Base images carry no SSH host keys or machine-id (generated per card on first boot) and have SSH disabled: the card is a phone-only appliance with no console login.
- Base images keep 768 MiB of rootfs headroom, because ZIMDATA follows root and blocks first-boot expansion.

### Changed

- README requirements no longer mention WSL; docs describe the prebuilt (exFAT) and dynamic (ext4) contracts side by side, and the V2 plan freezes the prebuilt writer invocation. `validate_repo.py` scopes the exFAT ban to the dynamic builder and checks the prebuilt writer.
- `pi-kiwix-device-config.service` now waits for the ZIMDATA mount.

## [0.2.1] - 2026-10-16

### Documentation
- Restructure the README as a concise, end-user-first document: quick start, requirements, card-size guidance, and troubleshooting stay up front; legacy first-boot, direct-on-Pi, and operator procedures moved to `HOWTO.md`.

## [0.2.0] - 2026-10-16

### Added
- Bundle a pinned, SHA-256-verified aria2c.exe into the portable release so prebuilt content downloads work without installing aria2.
- Show the emergency Wi-Fi name and password when the SD card build finishes, and save a printable label file (`EmergencyWebPi-WiFi-Label.html`) on the Desktop.
- Pre-flight the WSL requirement at wizard start: if it is missing or has no distribution, the app explains it in plain language and offers to run `wsl --install -d Ubuntu` automatically.
- `scripts/release-status.ps1` accepts `-Token` for private repositories and reports `INDETERMINATE` instead of `PENDING` when it cannot authenticate (the GitHub API answers 404 for private repos).
- START-HERE.txt and the README explain the expected SmartScreen warning ("Windows protected your PC") for the unsigned executable.

### Changed
- The portable app now requests administrator permission itself via UAC instead of requiring a manual right-click "Run as administrator".
- `install.sh` installs and enables `pi-kiwix-initial-sync.service` so the legacy path also retries first-boot content installation.
- `install.sh` starts the first sync with `--no-block` so a multi-hour content download cannot freeze the installer.
- Document the practical 128 GB SD card requirement for the full profile.
- The release EXE now carries a requireAdministrator manifest (ps2exe `-requireAdmin`), so Windows shows the elevation prompt at launch instead of relying on the runtime relaunch.
- Pin Ubuntu workflows to 24.04 and update GitHub Actions to Node 24-compatible major versions.

### Fixed
- Run the AP handoff (`switch-to-ap.sh`) as root via the systemd `+` exec prefix; it previously failed under the unprivileged service user, so first-boot mode never switched to standalone AP mode.
- Remove the deprecated `PermissionsStartOnly=true` directive (ignored since systemd 240).
- Document that Raspberry Pi OS does not execute a manually copied `firstrun.sh`; point legacy users to `prepare-sd-autoboot.ps1` or Imager customisation.
- `setup-ap.sh` refuses the published default AP passphrase so legacy builds cannot ship a known Wi-Fi password.
- Align repository validation with the root-run first-boot AP handoff (the CI invariant checker previously failed on `main`).

### Tests
- Add regression coverage for automatic elevation, bundled aria2, the Wi-Fi label, initial-sync installation, no-block sync start, default-passphrase rejection, aria2 attribution, and README guidance.
- Add regression coverage for the validate_repo AP-handoff invariant, WSL pre-flight, private-repo release status, SmartScreen guidance, and the requireAdministrator EXE manifest.
- Run the full release regression suite in CI, not only the status and initial-sync tests.

## [0.1.56] - 2026-09-24

### Changed
- Put the Recommended Prebuilt option before Advanced FirstBoot in the wizard.
- Move home Wi-Fi settings directly under the FirstBoot option and disable them for Prebuilt mode.
- Display the Emergency Web Pi app version and pinned Raspberry Pi OS release in the wizard.

### Tests
- Add regression coverage for wizard option order, Wi-Fi grouping, and version visibility.

## [0.1.55] - 2026-09-24

### Changed
- Make the relationship between FirstBoot content downloads and optional home Wi-Fi explicit in the wizard.
- Disable and clear home Wi-Fi fields while the recommended Prebuilt mode is selected.

### Tests
- Add regression coverage for the content-mode and home Wi-Fi control relationship.

## [0.1.54] - 2026-09-24

### Changed
- Show each library's name, size, and description together in the end-user wizard using a checked details list.
- Remove the disconnected single-item description and Learn More strip from the library picker.

### Fixed
- Give the primary `Estimate + Build` button enough width to display its complete label.

### Documentation
- Rewrite the end-user instructions with continuous numbering, plain-language choices, concrete Ethernet and Wi-Fi guidance, captive-portal navigation, and a clear boundary before advanced/operator procedures.

## [0.1.53] - 2026-09-24

### Changed
- Make the Windows end-user wizard select offline-ready Prebuilt content by default; retain FirstBoot as an advanced option.
- Move AP handoff until the initial content service succeeds, then disable upstream auto-connect and bring the standalone AP online.
- Return HTTP 200 for Android and Chrome captive-portal probes so they receive the local portal instead of a bare no-portal 204.

### Tests
- Add regression tests for the default content mode, non-root service identities, AP handoff ordering, captive-portal responses, dynamic status links, and temporary extraction safety.

## [0.1.52] - 2026-09-24

### Added
- Add optional home Wi-Fi fields to the Windows wizard for first-boot content downloads.
- Add common captive-portal probe endpoints and a catch-all status page route.

### Changed
- Run the four appliance systemd services under the dedicated non-root `emergency-web-pi` account.
- Attempt upstream Wi-Fi handoff after AP setup, keeping the emergency AP as a fallback.
- Build the status page library link from the request host instead of a hardcoded AP address.

### Fixed
- Reject running an incomplete portable bundle from a temporary extraction directory.
- Provision the service account and assign ownership of the ZIM data directory during installation and image creation.

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
