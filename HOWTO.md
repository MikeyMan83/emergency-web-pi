# How-To Operations Guide

This page is for routine operations after the Pi is deployed.
For the Windows appliance-builder contract and offline acceptance target, see [docs/APPLIANCE.md](docs/APPLIANCE.md).

## First bring-up

This section is for the current live-Pi install path.
It remains useful for development and recovery.

## Build appliance image on Windows

Use WSL-backed image build before writing the SD card:

Prerequisite: install WSL with an Ubuntu distribution (`wsl --install`).

```powershell
./scripts/build-appliance-image.ps1 -BaseImagePath C:\path\to\raspios-bookworm-arm64-lite.img.xz -ZimSourceDir C:\path\to\zim-files
```

For development images without preloaded content, add `-AllowEmptyZimData`.

Then write the SD card:

```powershell
./scripts/create-sd.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ImagePath artifacts/appliance.img -ManifestPath artifacts/appliance.img.manifest.json -Force
```

## Dynamic SD creation on Windows

To build a card with the latest profile content at creation time:

```powershell
./scripts/create-sd-dynamic.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -BaseImagePath artifacts/base-os.img -BaseManifestPath artifacts/base-os.img.manifest.json -ProfilePath profiles/medical-survival-zimlist.txt
```

This mode flashes the base image, creates a `ZIMDATA` exFAT partition from remaining space,
downloads profile entries with resume support, and copies them directly to SD.

1. Run installer:

```bash
./scripts/install.sh
```

2. Optional: enable standalone AP mode:

```bash
./scripts/setup-ap.sh
```

## Verify health

```bash
systemctl status pi-kiwix-serve.service --no-pager
journalctl -u pi-kiwix-serve.service -n 100 --no-pager
systemctl status pi-kiwix-sync.timer --no-pager
systemctl status pi-kiwix-sync.service --no-pager
```

Expected:
- `pi-kiwix-serve.service` is active and reachable on port `8080`.
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
