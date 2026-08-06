# Fully Unattended SD Prep (Advanced Optional)

This method prepares the SD card so the Pi installs and starts the full stack automatically on first boot.

Most users should use the simpler default path in `SD_CARD_QUICKSTART.md`.

## What this does

- Writes `firstrun.sh` to the boot partition.
- On first boot, Pi installs Docker, clones/pulls this repo, writes `.env` values, and starts containers.
- Optionally enables SSH by creating the `ssh` flag file.

## Step-by-step (Windows)

1. Flash Raspberry Pi OS Lite (64-bit) to the SD card with Raspberry Pi Imager.
2. Remove and reinsert SD card into your PC.
3. Find the boot partition drive letter (example `E:\`).
4. Run this command from the repo root:

```powershell
./scripts/prepare-sd-autoboot.ps1 \
  -BootPath E:\ \
  -RepoUrl https://github.com/MikeyMan83/pi-kiwix-survival.git \
  -RepoBranch main \
  -BootstrapUser <pi-username> \
  -ZimListRawUrl https://raw.githubusercontent.com/MikeyMan83/pi-kiwix-survival/main/profiles/medical-survival-zimlist.txt \
  -EnableSsh
```

5. Eject SD card safely and boot the Pi with internet available.

## Optional private-list token during prep

If your list URL requires auth, include `-GitHubToken` in the prep command.

Security note:
- This writes the token into boot-time script text on the SD card.
- Prefer adding token after first boot through `secrets/github_token` if possible.

## First-boot verification

After boot completes, open:

```text
http://<pi-ip>:8080
```

If needed, check logs on Pi:

```bash
docker compose logs -f kiwix-sync-agent
docker compose logs -f kiwix-server
```
