# pi-kiwix-survival

Offline-first Kiwix emergency appliance for Raspberry Pi 3B+.

<!-- SPACE_ESTIMATE:START -->
Published content size: **64.83 GB**
Published recommended minimum SD size: **77.79 GB**
Known subtotal (diagnostic): 64.83 GB
Last estimate refresh: 2026-08-07T15:01:20Z
<!-- SPACE_ESTIMATE:END -->

## Quickstart

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

curl -fsSL https://raw.githubusercontent.com/MikeyMan83/pi-kiwix-survival/main/scripts/bootstrap-pi.sh \
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

This configures `hostapd` + `dnsmasq` with defaults from `.env`.
If you want AP mode from first boot with no follow-up SSH step, use `-EnableAp`
with `scripts/prepare-sd-autoboot.ps1` so bootstrap runs it automatically after install.

## Documentation

- Setup and architecture: [README.md](README.md)
- Day-2 operations: [HOWTO.md](HOWTO.md)
- Release runbook: [docs/RELEASE.md](docs/RELEASE.md)
- Realtime SD size estimate: [docs/SPACE_ESTIMATE.md](docs/SPACE_ESTIMATE.md)
- Release history: [docs/CHANGELOG.md](docs/CHANGELOG.md)
- Current release version: [docs/VERSION](docs/VERSION)

## Practical recommendation

If your goal is the easiest reliable workflow, use:
1. Raspberry Pi Imager to create the SD card.
2. Run `scripts/prepare-sd-autoboot.ps1` against the boot partition.
3. Add `-EnableAp` if you want the Pi to become its own Wi-Fi hotspot automatically after setup.
4. Boot once on Wi-Fi and let first-boot automation deploy the stack.

Use Home Assistant only as an optional dashboard later.

### Optional fallback: one-command deploy over SSH

```bash
ssh <pi-user>@kiwixpi.local "curl -fsSL https://raw.githubusercontent.com/MikeyMan83/pi-kiwix-survival/main/scripts/bootstrap-pi.sh | sudo env BOOTSTRAP_USER=<pi-user> bash"
```

This command installs Docker (if needed), clones or updates the repo on Pi, writes the default medical-survival content URL into `.env`, and starts the containers.

The stack runs one container:
- `kiwix-server`: serves all `.zim` files in `./zim_data`.

Content syncing is handled by a host-level weekly systemd timer (`pi-kiwix-sync.timer`) that runs `scripts/sync.sh`.

## Why this pattern works

- Zero routine SSH maintenance after initial setup.
- Library state lives in Git (simple to audit and update).
- Interrupted large downloads resume automatically with `aria2c`.
- No Docker socket mount and no always-on polling sidecar.

## Offline-first behavior

This stack is designed to degrade gracefully when internet is unavailable:
- Online: weekly sync task checks GitHub and downloads new content.
- Offline: sync task exits success, logs offline warning, leaves existing content untouched.
- In both cases: `kiwix-server` still starts and serves every `.zim` file already stored in `zim_data/`.

No toggles are required to switch between connected and disconnected operation.

## Files in this repo

- `docker-compose.yml`: one-service stack (`kiwix-server` only).
- `scripts/sync.sh`: host-side one-shot sync task (systemd timer target).
- `scripts/install.sh`: one-command installer for compose + timer.
- `scripts/setup-ap.sh`: standalone AP setup (`hostapd` + `dnsmasq`).
- `scripts/enable-readonly.sh`: enables overlayfs read-only root mode.
- `.env.example`: environment values to copy into `.env`.
- `zimlist.txt.example`: starter format for your content list.
- `profiles/medical-survival-zimlist.txt`: recommended baseline list for emergency readiness.
- `zim_data/`: persistent data folder for downloaded `.zim` files and current `zimlist.txt`.

## One-time setup

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
docker compose up -d
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

Practical storage expectation:
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

- Keep this Pi trusted and avoid running untrusted containers alongside this stack.
- Never commit `.env` (it may contain your token).
- Prefer `GITHUB_TOKEN_FILE` over `GITHUB_TOKEN` so tokens are read from a file instead of env values.
- Enable overlayfs via `./scripts/enable-readonly.sh` for power-loss resilience.

## Troubleshooting

- Check logs:

```bash
docker compose logs -f kiwix-server
journalctl -u pi-kiwix-sync.service -n 200 --no-pager
```

- Force a manual sync test:

```bash
sudo systemctl start pi-kiwix-sync.service
```
