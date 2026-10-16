# Emergency Web Pi

Offline-first emergency web library appliance for Raspberry Pi 3B+.

Build a complete offline library — medical reference, disaster and survival guides, repair manuals, and full offline Wikipedia — onto an SD card from a Windows PC, with a guided app instead of command lines. The finished card boots into a Raspberry Pi that broadcasts its own emergency Wi-Fi and serves everything to any phone or laptop browser. No Internet is needed on the Pi.

## Highlights

- **One guided Windows app**: content choice, size check, and SD write in a single wizard.
- **Offline-ready out of the box**: the recommended prebuilt mode downloads everything during the build, so the finished card works without Internet immediately.
- **Self-hosted access point**: the Pi broadcasts its own Wi-Fi and shows a status page in any browser.
- **Verified downloads**: pinned, SHA-256-verified base image and content; release archives ship with checksums.

## Requirements

- A Windows 10/11 PC. The app needs WSL (Windows Subsystem for Linux) with Ubuntu — it checks this before anything is downloaded and offers to install it for you.
- An SD card and a card reader. The full **Everything** profile needs a **128 GB card**; smaller profiles fit smaller cards, and the wizard checks the selected card before writing.
- A Raspberry Pi 3B+ with its power supply.

## Get started (end users)

1. Download from Releases: https://github.com/MikeyMan83/emergency-web-pi/releases/latest
2. Download `EmergencyWebPi-<version>-windows.zip` (release asset).
3. Extract the zip completely to a normal folder (do not run directly from inside the ZIP preview).
4. Run `EmergencyWebPi.exe` from the extracted root folder, and click **Yes** when Windows asks for permission. The app needs this permission to write the SD card; it requests it automatically.
   If Windows first shows a blue box saying **Windows protected your PC**, click **More info** and then **Run anyway**. The app is not code-signed yet, so this warning is expected; the `.sha256.txt` file next to the download lets you verify it.
5. Click **Start End-User Wizard**, choose the information you want on the card, and choose the SD card you want to erase.
6. Leave **Recommended: prebuild content now** selected. The app downloads everything needed before it writes the card, so the finished card can work without Internet.
7. Insert the finished card into the Raspberry Pi and turn it on. If you chose the advanced first-boot download option, connect the Pi to the Internet first. An Ethernet cable plugs into the Pi's network socket, the larger socket beside the USB sockets.
8. On your phone or laptop, connect to the emergency Wi-Fi. The Wi-Fi name and password are shown by the app when the card is finished, and saved as a printable label file (`EmergencyWebPi-WiFi-Label.html`, on the Desktop of the PC that built the card). Write them on the card or its box.
9. Open a web browser and visit any ordinary website. The Pi should show its local status page automatically. If it does not, reconnect to the emergency Wi-Fi and try again.
10. On the status page, wait until the library says it is ready, then click **Open Library**.

**If the app does not start:** run `Launch-EmergencyWebPi.cmd` from the extracted root folder (it opens the same wizard), and check the newest log in `%LOCALAPPDATA%\EmergencyWebPi\startup-*.log`. Missing-file errors referencing a `...\AppData\Local\Temp\...` path mean the ZIP was not fully extracted first. The app keeps its download cache and generated profiles in `%LOCALAPPDATA%\EmergencyWebPi\workspace`, so the extracted folder stays clean.

## What's on the card

The default profile prioritizes emergency readiness:

- Medical reference for non-clinicians and clinicians (`mdwiki`, `wikem`)
- Disaster and wilderness readiness (`trueprepper`, `zimgit-post-disaster`)
- Repair and recovery content (`ifixit`, selected Stack Exchange archives)
- Broad reference: offline English and Dutch Wikipedia, without images

The full item list and per-item details are in [HOWTO.md](HOWTO.md).

## How it works

The card is a complete appliance image:

- `pi-kiwix-serve.service` serves every `.zim` file from a dedicated content partition.
- `pi-kiwix-status.service` shows a readiness page on port 80, so users see progress instead of a dead screen.
- A weekly sync timer refreshes content when the Pi has Internet and leaves existing content untouched when it does not. Interrupted large downloads resume automatically with `aria2c`.
- The build enforces a manifest contract — dedicated content partition, native Kiwix serving, and a matching image SHA-256 — before anything is written to the card.

## SD card size

<!-- SPACE_ESTIMATE:START -->
Published content size: **64.83 GB**
Published recommended minimum SD size: **77.79 GB**
Known subtotal (diagnostic): 64.83 GB
Last estimate refresh: 2026-10-16T11:14:34Z
<!-- SPACE_ESTIMATE:END -->

In practice the full **Everything** profile needs a **128 GB card** (the next size above the published minimum). Smaller profiles fit proportionally smaller cards; the wizard checks the selected card before writing.

Estimates are refreshed automatically by CI when the profile changes. Uses torrent metadata when available (with a header-based fallback for non-torrent links). If any library size cannot be resolved, published totals are withheld instead of showing a misleading number. Details: [docs/SPACE_ESTIMATE.md](docs/SPACE_ESTIMATE.md); machine-readable values: [docs/SPACE_ESTIMATE.json](docs/SPACE_ESTIMATE.json).

## Keeping content up to date

The Pi checks GitHub weekly for content updates when it has Internet. Set `SYNC_INTERVAL_SECONDS` in `.env` to tune check frequency. Default is `604800` (weekly).

## Advanced and maintenance use

End users never need anything below. For operators:

- [HOWTO.md](HOWTO.md) — day-2 operations: health checks, manual sync, backups, standalone AP mode, read-only root, recovery, direct installation on a running Pi, and the legacy first-boot path.
- [docs/APPLIANCE.md](docs/APPLIANCE.md) — the appliance build contract.
- [docs/RELEASE.md](docs/RELEASE.md) — release runbook.
- [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md) — attribution and open-source notices.
- [docs/V2_TAURI_PLAN.md](docs/V2_TAURI_PLAN.md) — the planned Tauri migration.

**Legacy note:** Raspberry Pi OS does **not** execute a `firstrun.sh` that is merely copied onto the boot partition. Use `scripts/prepare-sd-autoboot.ps1` (or Raspberry Pi Imager customisation) to wire first-boot automation; see [HOWTO.md](HOWTO.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| `portable/EmergencyWebPi.ps1` | Portable Windows frontend (build + SD write wizard). |
| `Launch-EmergencyWebPi.cmd` | Debug/support launcher for the same frontend. |
| `scripts/create-sd-dynamic.ps1` | Dynamic Windows SD builder (default operator entry point). |
| `scripts/create-sd.ps1` | Prepared-image writer with manifest invariants. |
| `scripts/build-appliance-image.ps1` | Windows wrapper for the appliance image build (runs in WSL). |
| `scripts/estimate_space.py` | CI-driven SD space estimator. |
| `scripts/validate_repo.py` | Repository invariant checks used by CI. |
| `scripts/systemd/` | Pi runtime services. |
| `scripts/` | Build, sync, AP setup, recovery, and release scripts. |
| `profiles/` | Content profiles; `medical-survival-zimlist.txt` is the recommended baseline. |
| `config/` | Pinned base image, content catalog, and example appliance config. |

## Safety notes

- Never commit `.env` (it may contain your token). Prefer `GITHUB_TOKEN_FILE` over `GITHUB_TOKEN`.
- Enable overlayfs via `./scripts/enable-readonly.sh` for power-loss resilience.
- Keep the Pi trusted; do not run untrusted software alongside the library stack.

## Versioning

The project follows Semantic Versioning. The authoritative current version is [docs/VERSION](docs/VERSION); user-visible changes are recorded in [docs/CHANGELOG.md](docs/CHANGELOG.md).