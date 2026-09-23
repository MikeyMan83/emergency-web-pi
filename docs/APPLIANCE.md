# Appliance Builder Contract

This document defines the Windows-first appliance build model for this repository.

## Product definition

Use the portable wizard or the dynamic Windows builder on a Windows PC with a blank SD card inserted.
The guided builder writes a complete, self-contained Raspberry Pi appliance to the SD card,
including the OS, Kiwix, the selected ZIM content, configuration, and emergency Wi-Fi setup.
It may optionally inject private configuration during the build.

Insert the SD card into the Raspberry Pi and it automatically starts its own emergency Wi-Fi.
In recommended first-boot mode, provide temporary Internet so selected content can download;
after installation completes, the same appliance works offline. Prebuilt mode serves the
selected library without Internet on first boot.

No manual runtime configuration is required. Prebuilt mode requires no first-boot Internet;
first-boot mode requires temporary Internet only until selected content is installed.

## Acceptance test

1. Insert a blank SD card into a Windows machine.
2. Run the portable wizard or `scripts/create-sd-dynamic.ps1`; both automatically download and verify the pinned official Raspberry Pi OS base image.
3. Remove the finished SD card.
4. Insert it into a Raspberry Pi 3B+.
5. Boot with temporary Internet connectivity for first-boot mode, or no Internet for prebuilt mode.
6. Connect a phone or laptop to the emergency Wi-Fi.
7. Browse to `http://10.42.0.1` and confirm the status page reports progress or ready.
8. Browse to `http://10.42.0.1:8080` when ready.
9. Confirm Kiwix starts and all expected ZIMs are present.

Maintenance path:

1. Provide upstream internet later.
2. Leave the emergency AP and Kiwix available locally.
3. Allow content updates in the background.

## Build-time vs runtime

Build time:

- Guided Windows builder entry point: `scripts/create-sd-dynamic.ps1`
- Prepared-image writer: `scripts/create-sd.ps1`
- Windows image build entry point: `scripts/build-appliance-image.ps1`
- Linux image build engine (invoked through WSL): `scripts/build-appliance-image.sh`
- Base OS image
- Application and system configuration
- Preloaded ZIM snapshot
- Private config injection
- Verification and manifest output

Runtime:

- Emergency AP always available
- Kiwix always available on the local appliance network
- Optional upstream internet only for content refresh
- Software/OS/appliance updates via a newly built SD card

## Legacy first-boot mode

The repository also includes a first-boot provisioning mode:

- `scripts/prepare-sd-autoboot.ps1`
- `scripts/bootstrap-pi.sh`
- `scripts/install.sh`

This mode is useful for development and recovery. It is separate from the offline appliance contract defined above.

## Builder inputs

- Target SD card / physical disk
- Appliance config file
- Pinned official Raspberry Pi OS Lite manifest and download cache
- Prepared-image mode also needs an appliance image (`.img`), its manifest, and the matching resolved config.
- Direct image builds use an optional local ZIM folder for preload into the dedicated `zimdata` partition.

Dynamic mode inputs:

- Pinned official Raspberry Pi OS Lite image, automatically downloaded and SHA-256 verified
- Profile list (`profiles/*.txt`)
- Windows disk target for SD write
- Local download cache directory
- Content mode: `FirstBoot` (default) or `Prebuilt`

## Build command

From Windows PowerShell:

Prerequisite: WSL with Ubuntu installed.

```powershell
./scripts/build-appliance-image.ps1 -BaseImagePath C:\path\to\raspios-bookworm-arm64-lite.img.xz -ZimSourceDir C:\path\to\zim-files
```

This produces:

- `artifacts/appliance.img`
- `artifacts/appliance.img.manifest.json`

Then write SD media with the resolved config path printed by the builder:

```powershell
./scripts/create-sd.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ConfigPath artifacts/appliance-config.json -ImagePath artifacts/appliance.img -ManifestPath artifacts/appliance.img.manifest.json -Force
```

Dynamic write + content population command:

```powershell
./scripts/create-sd-dynamic.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ProfilePath profiles/medical-survival-zimlist.txt
```

Portable frontend behavior for dynamic mode:

- Load profile presets from `profiles/*.txt`
- Select individual items with checkboxes
- Run preflight SD size estimation before the destructive write step
- Embed the selected catalog profile during appliance construction before the SD card is written
- Default to first-boot installation, with fully prebuilt offline cards available as an explicit choice

Runtime UX behavior:

- `pi-kiwix-status.service` serves a local status page on `http://10.42.0.1` shortly after boot
- `pi-kiwix-initial-sync.service` retries first-boot content installation while the pending marker exists
- `pi-kiwix-serve.service` serves the library on `http://10.42.0.1:8080`

The initial config example is provided at `config/appliance.example.json`.
Private local overrides belong in `config/appliance.local.json` and must not be committed.

## Required manifest invariants

`scripts/create-sd.ps1` verifies the manifest before writing:

- `storage.partitions` includes `boot`, `root`, and `zimdata`
- `runtime.serverMode=native-kiwix-serve`
- `runtime.zimDataOnDedicatedPartition=true`
- reject `runtime.overlayRootEnabled=true` when `runtime.docker.storageDriver=overlay2`
- `image.sha256` matches the actual image file hash
- `build.configSha256` matches the resolved config used to build the image