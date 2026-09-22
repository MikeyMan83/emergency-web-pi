# Appliance Builder Contract

This document defines the Windows-first appliance build model for this repository.

## Product definition

Run one command on a Windows PC with a blank SD card inserted.
The builder writes a complete, self-contained Raspberry Pi appliance to the SD card,
including the OS, Kiwix, the selected ZIM content, configuration, and emergency Wi-Fi setup.
It may optionally inject private configuration during the build.

Insert the SD card into the Raspberry Pi, power it on without internet,
and it automatically starts its own emergency Wi-Fi and serves the preloaded Kiwix library.

No first-boot installation, internet connection, GitHub access, or manual configuration
is required for the appliance to function.

## Acceptance test

1. Insert a blank SD card into a Windows machine.
2. Run `scripts/create-sd.ps1`.
3. Remove the finished SD card.
4. Insert it into a Raspberry Pi 3B+.
5. Boot with no internet connectivity.
6. Connect a phone or laptop to the emergency Wi-Fi.
7. Browse to `http://10.42.0.1:8080`.
8. Confirm Kiwix starts and all expected ZIMs are present.

Maintenance path:

1. Provide upstream internet later.
2. Leave the emergency AP and Kiwix available locally.
3. Allow content updates in the background.

## Build-time vs runtime

Build time:

- Windows builder entry point: `scripts/create-sd.ps1`
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
- Raspberry Pi OS Lite base image (`.img`, `.img.xz`, or `.zip`)
- Appliance image file (`.img`) provided via `-ImagePath` or discovered in `artifacts/`
- Appliance image manifest (`.img.manifest.json`) with build/runtime invariants
- Optional local ZIM folder for preload into dedicated `zimdata` partition

## Build command

From Windows PowerShell:

Prerequisite: WSL with Ubuntu installed.

```powershell
./scripts/build-appliance-image.ps1 -BaseImagePath C:\path\to\raspios-bookworm-arm64-lite.img.xz
```

This produces:

- `artifacts/appliance.img`
- `artifacts/appliance.img.manifest.json`

Then write SD media:

```powershell
./scripts/create-sd.ps1 -DiskNumber <N> -ImagePath artifacts/appliance.img -ManifestPath artifacts/appliance.img.manifest.json -Force
```

The initial config example is provided at `config/appliance.example.json`.
Private local overrides belong in `config/appliance.local.json` and must not be committed.

## Required manifest invariants

`scripts/create-sd.ps1` verifies the manifest before writing:

- `storage.partitions` includes `boot`, `root`, and `zimdata`
- `runtime.zimDataOnDedicatedPartition=true`
- reject `runtime.overlayRootEnabled=true` when `runtime.docker.storageDriver=overlay2`
- `image.sha256` matches the actual image file hash