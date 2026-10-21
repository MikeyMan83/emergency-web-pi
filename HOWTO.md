# How-To Operations Guide

This page is for routine operations after the Pi is deployed.
For the Windows appliance-builder contract and offline acceptance target, see [docs/APPLIANCE.md](docs/APPLIANCE.md).

## End-user flow

For normal deployment, use the portable app creator:

1. Go to https://github.com/MikeyMan83/emergency-web-pi/releases/latest.
2. Download `EmergencyWebPi-<version>-windows.zip`.
3. Extract it fully to a regular folder (do not run from within the ZIP viewer).
4. Start `EmergencyWebPi.exe` from the extracted root folder.
5. The app opens directly into the creator. Choose the information you want on the card (the recommended profile is preselected), then choose the SD card you want to erase.
6. Leave **Prepare everything now** selected. The app downloads the library before writing, so the finished card works without Internet.
7. Insert the card in the Pi and turn it on. If you selected the advanced first-boot option, connect the Pi to the Internet first with an Ethernet cable in the larger network socket beside the USB sockets.
8. Connect your phone or laptop to the emergency Wi-Fi. Use the Wi-Fi name and password supplied by the person who prepared the card; they should be written on the card or its label.
9. Open a browser and visit any ordinary website. The local status page should appear automatically.
10. Wait for the status page to say the library is ready, then click **Open Library**.

---

## Advanced/operator flow

The rest of this guide is for testing, recovery, and direct maintenance. Normal card recipients do not need it. End users never need WSL, `create-sd-dynamic.ps1`, or any script below: the creator uses the native `scripts/create-sd-prebuilt.ps1`.

Fallback when no bundle asset is attached yet: download `Source code (zip)` and run `Launch-EmergencyWebPi.cmd` from the extracted root.

The EXE and CMD launcher open the same creator. CMD starts the bundled PowerShell frontend directly, which is useful when Windows SmartScreen blocks the unsigned EXE.

For testing or recovery, select `Developer Tools` in the creator window to open direct build inputs, prepared-image writing, diagnostics, logs, and artifacts. Normal users do not need this workspace.

If you get a missing-file error under `AppData\\Local\\Temp`, close the app, extract the ZIP fully, and start again from the extracted folder.

No manual script sequence is required for this path.

The EXE is the normal entry point. The CMD launcher starts the same frontend directly:

```powershell
.\EmergencyWebPi.exe
.\Launch-EmergencyWebPi.cmd
```

If the frontend does not appear, inspect the newest log in `%LOCALAPPDATA%\EmergencyWebPi\startup-*.log`. The app keeps its download cache, generated profiles, and temporary build workspace in `%LOCALAPPDATA%\EmergencyWebPi\workspace`, rather than adding files to the extracted release folder. Attribution and open-source notices are in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

## Supported appliance modes

This project is a Windows-first appliance builder. The guided build creates a complete appliance image and writes it to SD; content is downloaded either on first boot or during the Windows build. Prebuilt mode works without Internet immediately. First-boot mode needs temporary Internet access until selected content is installed. Both modes need no manual runtime configuration and work offline after installation completes.

Three modes are supported:
- Guided appliance-build mode: the portable creator or `scripts/create-sd-dynamic.ps1` builds and writes an appliance with first-boot or prebuilt content installation.
- Prepared-image mode: `scripts/create-sd.ps1` writes an image previously built by `scripts/build-appliance-image.ps1`.
- Legacy first-boot mode: `firstrun.sh` + `bootstrap-pi.sh` + `install.sh` provision on first boot.

## Build appliance image on Windows

Use WSL-backed image build before writing the SD card:

Prerequisite: install WSL with an Ubuntu distribution (`wsl --install`).

```powershell
./scripts/build-appliance-image.ps1 -ZimSourceDir C:\path\to\zim-files
```

For development images without preloaded content, add `-AllowEmptyZimData`.

Then write the SD card:

```powershell
./scripts/create-sd.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ConfigPath artifacts/appliance-config.json -ImagePath artifacts/appliance.img -ManifestPath artifacts/appliance.img.manifest.json -Force
```

The prepared-image writer enforces manifest invariants and verifies the image hash before writing. The manifest must declare a dedicated `zimdata` partition, native `kiwix-serve`, `runtime.zimDataOnDedicatedPartition=true`, no `overlayRootEnabled=true` with Docker `overlay2`, and a matching SHA-256 for the image. The image builder resolves the AP password into an ignored config artifact and records its hash in the manifest. Pass that emitted config to `create-sd.ps1`; the writer rejects placeholder passwords and config/image mismatches.

If `-ImagePath` is omitted, `create-sd.ps1` auto-uses `artifacts/appliance.img`, `artifacts/emergency-web-pi.img`, `appliance.img`, or the newest `artifacts/*.img`. `build-appliance-image.ps1` requires `-ZimSourceDir` for offline-ready images; use `-AllowEmptyZimData` only for development images that will sync content later.

## Dynamic SD creation on Windows

To build a card with the latest profile content at creation time:

```powershell
./scripts/create-sd-dynamic.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ProfilePath profiles/medical-survival-zimlist.txt
```

This mode defaults to first-boot content installation. It builds an appliance image with
the selected profile in its ext4 `zimdata` partition, then writes that final image to SD.
The creator defaults to offline-ready prebuilt content, while direct PowerShell use defaults
to first-boot mode. Add `-ContentMode Prebuilt` when the Windows PC should download content before writing.
In the portable app, open **Developer Tools**, use the **Content** tab to choose profile entries,
then use **SD & Output** to review the capacity estimate before confirming the write.

## Verify health

```bash
systemctl status pi-kiwix-serve.service --no-pager
journalctl -u pi-kiwix-serve.service -n 100 --no-pager
systemctl status pi-kiwix-sync.timer --no-pager
systemctl status pi-kiwix-sync.service --no-pager
```

Expected:
- `/var/lib/pi-kiwix-zimdata` is mounted.
- `pi-kiwix-serve.service` is active and reachable on port `8080`.
- In first-boot mode, `pi-kiwix-initial-sync.service` retries until the selected content is installed.
- `pi-kiwix-sync.timer` is enabled and scheduled weekly.

## Run sync now

```bash
sudo systemctl start pi-kiwix-sync.service
journalctl -u pi-kiwix-sync.service -n 200 --no-pager
```

Expected:
- Offline: sync exits 0 and leaves existing content untouched.
- Online: new ZIM files download and are added to `library.xml`.
- `pi-kiwix-serve.service` is running and reachable on port `8080`.

## Update software stack

```bash
git pull --ff-only
./scripts/install.sh
```

## Backup important local data

Back up these paths:
- `zim_data/` (all downloaded knowledge files)
- `.env` (configuration)
- `secrets/github_token` (if used)

## Change sync frequency

Edit timer schedule:

- `/etc/systemd/system/pi-kiwix-sync.timer`

Then reload and restart timer:

```bash
sudo systemctl daemon-reload
sudo systemctl restart pi-kiwix-sync.timer
systemctl list-timers pi-kiwix-sync.timer
```

## Standalone AP mode

To configure own Wi-Fi AP (no router dependency):

```bash
./scripts/setup-ap.sh
```

Client access URL after connecting to AP SSID: `http://10.42.0.1:8080`.

`scripts/setup-ap.sh` configures AP mode through NetworkManager shared mode and
adds a wildcard DNS sinkhole to keep modern phones connected to the offline network.

For zero-touch deployment from Windows, `scripts/prepare-sd-autoboot.ps1 -EnableAp`
adds `BOOTSTRAP_ENABLE_AP=1` to `firstrun.sh`, so first boot installs the stack,
runs the first sync while internet is still available, and only then switches
the Pi into standalone AP mode.

## Read-only root mode (power-loss resilience)

Overlayfs backs the root filesystem with RAM: writes appear to succeed but
are discarded on reboot. `zim_data/` must live on separate, real storage
*before* enabling overlay, or downloaded content will silently vanish every
reboot instead of persisting. `enable-readonly.sh` handles this migration
first, then enables overlay:

```bash
./scripts/enable-readonly.sh
```

You'll be prompted for a device to hold `zim_data/` - a spare SD partition
or (recommended, simplest) a separate USB flash drive/SSD. The script
formats it, migrates any existing content, updates `.env`, and only then
enables overlay. Reboot once it finishes.

If you've already separated `zim_data/` onto its own storage and just want
to (re-)enable overlay, answer `skip` when prompted.

Important trade-off:
- While overlayfs is enabled, persistent OS/package/script edits are not retained.
- `zim_data/` is unaffected - it's on separate storage now, so weekly sync keeps working normally.
- Before upgrades or config edits, disable overlayfs:

```bash
sudo raspi-config nonint disable_overlayfs
sudo reboot
```

After maintenance, re-enable overlayfs:

```bash
sudo raspi-config nonint enable_overlayfs
sudo reboot
```

## Common recovery actions

If sync cannot download list:
1. Confirm `GITHUB_URL` is correct.
2. Confirm token file exists and is readable if repo is private.
3. Check outbound internet on the Pi.
4. Check logs: `journalctl -u pi-kiwix-sync.service -n 200 --no-pager`.

If a content entry is unavailable (dead torrent, no seeders, or unreachable URL):
1. Check `zim_data/sync.log` for warnings.
2. Sync continues to next entries by design.

If Kiwix UI is empty:
1. Confirm `.zim` files exist under `zim_data/`.
2. Rebuild library:

```bash
LIBRARY="$(grep '^ZIM_DATA_DIR=' .env | cut -d= -f2-)/library.xml"
: > "$LIBRARY"
for f in "$(dirname "$LIBRARY")"/*.zim; do
  [ -e "$f" ] || continue
  kiwix-manage "$LIBRARY" add "$f" 2>/dev/null || true
done
sudo systemctl restart pi-kiwix-serve.service
```

## Legacy first-boot installation

### Flash the SD card

1. Open Raspberry Pi Imager.
2. Select Raspberry Pi OS Lite (64-bit).
3. In Advanced Options, set the hostname, username/password, Wi-Fi credentials, and enable SSH.
4. Write the card.

### Wire zero-touch first boot

Raspberry Pi OS does **not** execute a `firstrun.sh` that is merely copied onto the boot partition. On Windows, run `scripts/prepare-sd-autoboot.ps1` after flashing; add `-EnableAp` for standalone AP mode. Alternatively, use Raspberry Pi Imager's OS customisation to run a first-boot script that downloads and executes `scripts/bootstrap-pi.sh`:

```bash
#!/bin/bash
set -euo pipefail

BOOTSTRAP_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
if [ -z "$BOOTSTRAP_USER" ]; then
  BOOTSTRAP_USER="pi"
fi

curl -fsSL https://raw.githubusercontent.com/MikeyMan83/emergency-web-pi/main/scripts/bootstrap-pi.sh \
  | env BOOTSTRAP_USER="$BOOTSTRAP_USER" bash
```

Boot the Pi once while internet is available, wait for provisioning and the first sync attempt, then verify Kiwix at `http://<pi-ip>:8080` or, in standalone AP mode, `http://10.42.0.1:8080`.

### Optional standalone AP mode

Run once on the Pi to make it independent of a home router or DHCP:

```bash
./scripts/setup-ap.sh
```

This configures a NetworkManager hotspot with defaults from `.env`, including a captive-portal DNS sinkhole so phones stay attached to the offline AP. For AP mode from first boot without a follow-up SSH step, use `-EnableAp` with `scripts/prepare-sd-autoboot.ps1` so bootstrap enables it after installation.

## Direct installation on a running Pi

Use this only when installing directly on an already running Pi rather than building the standard offline appliance card.

1. Create a GitHub repo with a `zimlist.txt` file.
2. Add one content URL per line in `zimlist.txt` (torrent or direct `.zim`).
3. Clone this repo on the Pi.
4. Create `.env` from the example:

```bash
cp .env.example .env
```

5. Edit `.env`: set `GITHUB_URL` to the raw `zimlist.txt` URL. For the quickest start, host `profiles/medical-survival-zimlist.txt` in your GitHub repo and point `GITHUB_URL` to that raw file. If the repo is private, set `GITHUB_TOKEN` to a fine-grained token with read-only Contents access.
6. Install and start the stack:

```bash
./scripts/install.sh
```

7. Open Kiwix at `http://<pi-ip>:8080`.

### Update content later

1. Edit `zimlist.txt` in GitHub from a phone or PC.
2. Commit changes.
3. The weekly sync timer picks changes up automatically.

Set `SYNC_INTERVAL_SECONDS` in `.env` to tune check frequency. The default is `604800` (weekly).

### One-command deploy over SSH

```bash
ssh <pi-user>@kiwixpi.local "curl -fsSL https://raw.githubusercontent.com/MikeyMan83/emergency-web-pi/main/scripts/bootstrap-pi.sh | sudo env BOOTSTRAP_USER=<pi-user> bash"
```

This installs required host dependencies, clones or updates the repo on the Pi, writes the default medical-survival content URL into `.env`, and enables native `kiwix-serve` and sync services.

Runtime services:
- `pi-kiwix-serve.service` serves all `.zim` files from `ZIM_DATA_DIR` and rebuilds `library.xml` from local ZIM files before serving.
- `pi-kiwix-initial-sync.service` retries first-boot content installation until the selected profile is complete.
- `pi-kiwix-sync.timer` runs periodic sync and library rebuild through `scripts/sync.sh`.
- `pi-kiwix-status.service` serves the startup/status page on port 80 so users see readiness progress and avoid unplugging early.

## Baseline content profile

The included medical-survival profile prioritizes:
- Medical reference for non-clinicians and clinicians (`mdwiki`, `wikem`).
- Disaster and wilderness readiness (`trueprepper`, `zimgit-post-disaster`).
- Repair and recovery content (`ifixit`, selected Stack Exchange archives).
- Broad reference (`wikipedia_en_all_nopic`, `wikipedia_nl_all_nopic`).

The current profile includes:
- Wikipedia Dutch (no images): `wikipedia_nl_all_nopic`
- Wikipedia English (no images): `wikipedia_en_all_nopic`
- MDWiki medical encyclopedia: `mdwiki_en_all_maxi`
- WikEM emergency medicine reference: `wikem_en_all_maxi`
- TruePrepper survival guidance: `trueprepper.com_en_all_2026-05`
- Post-disaster recovery guide: `zimgit-post-disaster_en_2024-05`
- iFixit repair manuals: `ifixit_en_all_2025-12`
- DIY Stack Exchange archive: `diy.stackexchange.com_en_all_2026-02`
- Mechanics Stack Exchange archive: `mechanics.stackexchange.com_en_all_2026-02`
- Woodworking Stack Exchange archive: `woodworking.stackexchange.com_en_all_2026-02`
- Raspberry Pi Stack Exchange archive: `raspberrypi.stackexchange.com_en_all_2026-02`

The English and Dutch Wikipedia (no images) archives dominate storage and are typically far above a few GB. If the estimate is single-digit GB for this profile, treat it as incomplete until all item sizes are resolved.

## Offline-first behavior

The stack degrades gracefully when internet is unavailable:
- Online, the weekly sync checks GitHub and downloads new content.
- Offline, sync exits successfully, logs an offline warning, and leaves existing content untouched.
- In either case, `kiwix-serve` starts and serves every `.zim` file already stored in `zim_data/`.

No toggles are required to switch between connected and disconnected operation. There is no routine SSH maintenance after initial setup; library state lives in Git for auditability, interrupted large downloads resume automatically with `aria2c`, and appliance mode has no container runtime dependency.

## Repository file reference

- `scripts/build-appliance-image.ps1`: Windows wrapper for appliance image build.
- `scripts/build-appliance-image.sh`: Linux image build engine used through WSL.
- `scripts/create-sd.ps1`: Windows appliance-builder entry point.
- `scripts/create-sd-dynamic.ps1`: dynamic Windows SD builder (verified base image, profile, and ext4 appliance image).
- `scripts/rebuild-library.sh`: host-side local `library.xml` rebuild helper.
- `portable/EmergencyWebPi.ps1`: portable Windows frontend for build and SD write.
- `Launch-EmergencyWebPi.cmd`: one-click launcher for the portable frontend.
- `scripts/sync.sh`: host-side one-shot sync task and systemd timer target.
- `scripts/install.sh`: one-command installer for native Kiwix service and timer.
- `scripts/systemd/pi-kiwix-serve.service`: native Kiwix runtime service.
- `scripts/setup-ap.sh`: standalone AP setup (NetworkManager hotspot and captive DNS).
- `scripts/enable-readonly.sh`: enables overlayfs read-only root mode.
- `config/appliance.example.json`: example private appliance build config.
- `.env.example`: environment values to copy into `.env`.
- `zimlist.txt.example`: starter format for a content list.
- `profiles/medical-survival-zimlist.txt`: recommended baseline list for emergency readiness.
- `zim_data/`: persistent data folder for downloaded `.zim` files and current `zimlist.txt`.

## Estimate and release references

GitHub Actions refreshes [docs/SPACE_ESTIMATE.md](docs/SPACE_ESTIMATE.md) and [docs/SPACE_ESTIMATE.json](docs/SPACE_ESTIMATE.json) from the current profile list. Estimate updates trigger automatically on profile changes in `main`, and appear in the PR job summary before merge. Uses torrent metadata when available (with a header-based fallback for non-torrent links). If any library size cannot be resolved, published totals are withheld instead of showing a misleading number.

Versioning follows Semantic Versioning (`MAJOR.MINOR.PATCH`); [docs/VERSION](docs/VERSION) is authoritative and user-visible changes belong in [docs/CHANGELOG.md](docs/CHANGELOG.md) under Unreleased before moving into a dated release section.
