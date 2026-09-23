# Emergency Web Pi

Offline-first emergency web library appliance for Raspberry Pi 3B+.

## Windows end-to-end appliance flow

Build and write a complete appliance SD card from Windows.

End-user path:

1. Download from Releases: https://github.com/MikeyMan83/emergency-web-pi/releases/latest
2. Download `EmergencyWebPi-<version>-windows.zip` (release asset).
3. Extract the zip completely to a normal folder (do not run directly from inside the ZIP preview).
4. Run `EmergencyWebPi.exe` from the extracted root folder.
5. Start the end-user wizard, select catalog items, then select your SD card.
   Emergency Web Pi automatically downloads and SHA-256 verifies its pinned official Raspberry Pi OS Lite base image.
7. Choose a content mode:
   - **Recommended: download on first boot.** The Pi prepares the appliance quickly, then downloads selected catalogs when it first has Internet access.
   - **Fully prebuild.** The Windows PC downloads selected catalogs before writing, so the Pi needs no Internet on first boot.
8. Insert the card into the Pi and boot. For first-boot mode, provide temporary Internet to the Pi, such as Ethernet.
9. Join the Pi Wi-Fi and open http://10.42.0.1 to watch installation progress.
10. When installation is complete, open http://10.42.0.1:8080 for the offline library.

Fallback if no release asset is attached yet: download `Source code (zip)` and run `Launch-EmergencyWebPi.cmd` from the extracted root.

Portable frontend option:

```powershell
.\EmergencyWebPi.exe
```

Debug/support fallback launcher:

```powershell
.\Launch-EmergencyWebPi.cmd
```

Launcher policy:
- `EmergencyWebPi.exe` is the primary app entry point.
- `Launch-EmergencyWebPi.cmd` is a fallback helper that tries EXE first, then script fallback only if needed.

If you see missing-file errors that reference a `...\AppData\Local\Temp\...` path,
you are likely launching from a temporary/partial extraction context. Extract the full ZIP first.

The portable app wraps the same validated script engine used below.

Attribution and open-source notices are in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

The wizard uses a pinned official Raspberry Pi OS Lite base image, catalog item selection,
and preflight size estimation before write. Both content modes use the same
ext4 appliance layout and runtime; they differ only in when selected catalogs download.

Advanced script-first paths are still available below for operators.

Dynamic mode (recommended for fresh content at build time):

```powershell
./scripts/create-sd-dynamic.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ProfilePath profiles/medical-survival-zimlist.txt
```

This mode defaults to `-ContentMode FirstBoot`, which writes the selected profile
to the ext4 `zimdata` partition and downloads catalogs automatically on the Pi.
Use `-ContentMode Prebuilt` to download selected ZIM files on Windows and create
a card that is offline-ready at its first boot.

In the portable app, dynamic mode includes:
- profile preset loading,
- item-level checkboxes (choose exactly what to include),
- preflight size estimation before the destructive write step.

1. Download Raspberry Pi OS Lite (64-bit) image (`.img`, `.img.xz`, or `.zip`).
2. Ensure WSL with Ubuntu is installed (`wsl --install`).
3. Build appliance image + manifest in WSL:

```powershell
./scripts/build-appliance-image.ps1 -BaseImagePath C:\path\to\2026-xx-xx-raspios-bookworm-arm64-lite.img.xz -ZimSourceDir C:\path\to\zim-files
```

4. Write the built image to SD:

```powershell
./scripts/create-sd.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ConfigPath artifacts/appliance-config.json -ImagePath artifacts/appliance.img -ManifestPath artifacts/appliance.img.manifest.json -Force
```

This path enforces manifest invariants and image hash verification before write.

## Appliance goal

This project is designed as a Windows-first appliance builder:

- Use the portable wizard or `scripts/create-sd-dynamic.ps1`; both automatically download and verify the pinned Raspberry Pi OS Lite base image.
- The guided build creates a complete appliance image and writes it to the SD card. Content downloads either on first boot or during the Windows build, based on the selected mode.
- Insert the SD card into the Pi and boot. Prebuilt mode works without Internet immediately; first-boot mode needs temporary Internet for its selected content.
- Connect to the emergency Wi-Fi and browse the status page while installation runs, then use the offline library when it is ready.

Prebuilt mode requires no first-boot installation or Internet connection. First-boot mode
requires temporary Pi Internet access until selected content is installed; both modes need
no manual runtime configuration and work offline after content installation completes.

The appliance build contract is defined in [docs/APPLIANCE.md](docs/APPLIANCE.md).

Three supported modes exist in this repository:
- Guided appliance-build mode: the portable wizard or `scripts/create-sd-dynamic.ps1` builds and writes an appliance with first-boot or prebuilt content installation.
- Prepared-image mode: `scripts/create-sd.ps1` writes an image previously built by `scripts/build-appliance-image.ps1`.
- Legacy first-boot mode: `firstrun.sh` + `bootstrap-pi.sh` + `install.sh` provision on first boot.

<!-- SPACE_ESTIMATE:START -->
Published content size: **64.83 GB**
Published recommended minimum SD size: **77.79 GB**
Known subtotal (diagnostic): 64.83 GB
Last estimate refresh: 2026-09-23T11:15:28Z
<!-- SPACE_ESTIMATE:END -->

## Legacy first-boot quickstart

### 1. Flash SD card

1. Open Raspberry Pi Imager.
2. Select Raspberry Pi OS Lite (64-bit).
3. In Advanced Options, set:
    - hostname,
    - username/password,
    - Wi-Fi credentials,
    - SSH enabled.
4. Write the card.

### 2. Zero-touch first boot setup

Add a file named `firstrun.sh` to the SD card boot partition:

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

### 3. Boot and verify

1. Boot the Pi once while internet is available.
2. Wait for provisioning and first sync attempt.
3. Access Kiwix:
    - home network mode: `http://<pi-ip>:8080`
    - standalone AP mode: `http://10.42.0.1:8080`

### 4. Optional standalone AP mode

Run once on Pi to make it independent from home router/DHCP:

```bash
./scripts/setup-ap.sh
```

This configures a NetworkManager hotspot with defaults from `.env`, including
a captive-portal DNS sinkhole so phones stay attached to the offline AP.
If you want AP mode from first boot with no follow-up SSH step, use `-EnableAp`
with `scripts/prepare-sd-autoboot.ps1` so bootstrap runs it automatically after install.

## Documentation

- Setup and architecture: [README.md](README.md)
- Day-2 operations: [HOWTO.md](HOWTO.md)
- Release runbook: [docs/RELEASE.md](docs/RELEASE.md)
- Realtime SD size estimate: [docs/SPACE_ESTIMATE.md](docs/SPACE_ESTIMATE.md)
- Release history: [docs/CHANGELOG.md](docs/CHANGELOG.md)
- Current release version: [docs/VERSION](docs/VERSION)

## Recommended workflow

For most users, this is the simplest reliable path:
1. Use the portable wizard, or run `scripts/create-sd-dynamic.ps1`.
2. Select content and let the build finish writing the SD card.
3. For first-boot mode, boot the Pi with temporary Internet access and wait for installation to complete. Prebuilt mode needs no Internet.
4. Connect to the AP and browse to `http://10.42.0.1` for progress, then `http://10.42.0.1:8080` for the library.

Use legacy first-boot setup only if you specifically need direct installation on a running Pi.

`scripts/create-sd.ps1` is the prepared-image writer.
If `-ImagePath` is omitted, it auto-uses `artifacts/appliance.img`,
`artifacts/emergency-web-pi.img`, `appliance.img`, or the newest `artifacts/*.img`.
`scripts/build-appliance-image.ps1` requires `-ZimSourceDir` for offline-ready images;
use `-AllowEmptyZimData` only for development images that will sync content later.
`scripts/create-sd-dynamic.ps1` downloads and verifies the pinned Raspberry Pi OS base image,
then uses the selected profile to build the final ext4 appliance image.
The builder requires an image manifest (`.img.manifest.json`) and rejects images unless they declare:
- dedicated `zimdata` partition,
- `runtime.serverMode=native-kiwix-serve`,
- `runtime.zimDataOnDedicatedPartition=true`,
- no `overlayRootEnabled=true` with Docker `overlay2`,
- matching SHA256 for the image file.
The image builder resolves the AP password once into an ignored config artifact
and records its SHA-256 in the image manifest. Always pass that emitted resolved
config to `create-sd.ps1`; the writer rejects placeholders and config/image mismatches.

### One-command deploy over SSH

```bash
ssh <pi-user>@kiwixpi.local "curl -fsSL https://raw.githubusercontent.com/MikeyMan83/emergency-web-pi/main/scripts/bootstrap-pi.sh | sudo env BOOTSTRAP_USER=<pi-user> bash"
```

This command installs required host dependencies, clones or updates the repo on Pi,
writes the default medical-survival content URL into `.env`, and enables native
`kiwix-serve` and sync services.

Runtime services:
- `pi-kiwix-serve.service`: serves all `.zim` files from `ZIM_DATA_DIR`.
- `pi-kiwix-initial-sync.service`: retries first-boot content installation until the selected profile is complete.
- `pi-kiwix-sync.timer`: runs periodic sync and library rebuild.
- `pi-kiwix-status.service`: serves a startup/status page on port `80`.

`pi-kiwix-serve.service` runs a pre-start library rebuild from local ZIM files,
so copied content from dynamic SD creation is indexed even without internet.

`pi-kiwix-status.service` starts quickly after boot and shows readiness progress,
so users get immediate feedback and can avoid unplugging early.

Content syncing is handled by a host-level weekly systemd timer (`pi-kiwix-sync.timer`) that runs `scripts/sync.sh`.

## Why this pattern works

- Zero routine SSH maintenance after initial setup.
- Library state lives in Git (simple to audit and update).
- Interrupted large downloads resume automatically with `aria2c`.
- No container runtime dependency in appliance mode.

## Offline-first behavior

This stack is designed to degrade gracefully when internet is unavailable:
- Online: weekly sync task checks GitHub and downloads new content.
- Offline: sync task exits success, logs offline warning, leaves existing content untouched.
- In both cases: `kiwix-serve` still starts and serves every `.zim` file already stored in `zim_data/`.

No toggles are required to switch between connected and disconnected operation.

## Files in this repo

- `scripts/build-appliance-image.ps1`: Windows wrapper for appliance image build.
- `scripts/build-appliance-image.sh`: Linux image build engine used through WSL.
- `scripts/create-sd.ps1`: Windows appliance-builder entry point.
- `scripts/create-sd-dynamic.ps1`: dynamic Windows SD builder (automatic verified base image + profile + ext4 appliance image build).
- `scripts/rebuild-library.sh`: host-side local `library.xml` rebuild helper.
- `portable/EmergencyWebPi.ps1`: portable Windows frontend for build + SD write.
- `portable/Launch-EmergencyWebPi.cmd`: one-click launcher for the portable frontend.
- `scripts/sync.sh`: host-side one-shot sync task (systemd timer target).
- `scripts/install.sh`: one-command installer for native kiwix service + timer.
- `scripts/systemd/pi-kiwix-serve.service`: native kiwix runtime service.
- `scripts/setup-ap.sh`: standalone AP setup (NetworkManager hotspot + captive DNS).
- `scripts/enable-readonly.sh`: enables overlayfs read-only root mode.
- `config/appliance.example.json`: example private appliance build config.
- `.env.example`: environment values to copy into `.env`.
- `zimlist.txt.example`: starter format for your content list.
- `profiles/medical-survival-zimlist.txt`: recommended baseline list for emergency readiness.
- `zim_data/`: persistent data folder for downloaded `.zim` files and current `zimlist.txt`.

## One-time setup (advanced)

Use this section only when you want to install directly on an already running Pi.
For the standard offline appliance experience, follow the Windows end-to-end flow above.

1. Create a GitHub repo with a `zimlist.txt` file.
2. Add one content URL per line in `zimlist.txt` (torrent or direct `.zim`).
3. On the Pi, clone this repo.
4. Create `.env` from the example:

```bash
cp .env.example .env
```

5. Edit `.env`:
   - Set `GITHUB_URL` to your raw `zimlist.txt` URL.
   - For quickest start, host `profiles/medical-survival-zimlist.txt` in your GitHub repo and point `GITHUB_URL` to that raw file.
   - If your repo is private, set `GITHUB_TOKEN` to a fine-grained token with read-only Contents access.
6. Start the stack:

```bash
./scripts/install.sh
```

7. Open Kiwix at `http://<pi-ip>:8080`.

## Updating content later

1. Edit `zimlist.txt` in GitHub (phone or PC).
2. Commit changes.
3. Weekly sync timer picks changes up automatically.

Set `SYNC_INTERVAL_SECONDS` in `.env` to tune check frequency. Default is `604800` (weekly).

## Recommended baseline content

The included medical-survival profile prioritizes:
- Medical reference for non-clinicians and clinicians (`mdwiki`, `wikem`).
- Disaster and wilderness readiness (`trueprepper`, `zimgit-post-disaster`).
- Repair/recovery content (`ifixit`, selected Stack Exchange archives).
- Broad reference (`wikipedia_en_all_nopic`, `wikipedia_nl_all_nopic`).

Storage expectation:
- English + Dutch Wikipedia (nopic) dominate size and are typically far above a few GB.
- If any estimate is single-digit GB for this profile, treat it as incomplete until all item sizes are resolved.

### What's Included (Current Profile)

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

High-overhead items:
- `wikipedia_en_all_nopic`
- `wikipedia_nl_all_nopic`

## Realtime SD space estimate

GitHub Actions updates [docs/SPACE_ESTIMATE.md](docs/SPACE_ESTIMATE.md) from the current profile list.
Machine-readable values are published to [docs/SPACE_ESTIMATE.json](docs/SPACE_ESTIMATE.json).

- Triggered automatically on profile changes in `main`.
- Visible in PR job summary before merge.
- Uses torrent metadata when available (with a header-based fallback for non-torrent links).
- Strict publish policy: if any library size cannot be resolved, published totals are withheld instead of showing a misleading number.

## Versioning and releases

- Versioning follows Semantic Versioning (`MAJOR.MINOR.PATCH`).
- The authoritative current version is stored in [docs/VERSION](docs/VERSION).
- Every user-visible change should be recorded in [docs/CHANGELOG.md](docs/CHANGELOG.md) under `Unreleased`, then moved to a dated release section.

## Safety notes

- Keep this Pi trusted and avoid running untrusted software alongside this stack.
- Never commit `.env` (it may contain your token).
- Prefer `GITHUB_TOKEN_FILE` over `GITHUB_TOKEN` so tokens are read from a file instead of env values.
- Enable overlayfs via `./scripts/enable-readonly.sh` for power-loss resilience.

## Troubleshooting

- Check logs:

```bash
journalctl -u pi-kiwix-serve.service -n 200 --no-pager
journalctl -u pi-kiwix-sync.service -n 200 --no-pager
```

- Force a manual sync test:

```bash
sudo systemctl start pi-kiwix-sync.service
```
