# pi-kiwix-survival

HACS-style GitOps workflow for an offline-ready Raspberry Pi Kiwix library.

Start here for fastest setup on an RPi 3B+: [SD_CARD_QUICKSTART.md](SD_CARD_QUICKSTART.md)
For zero-touch first boot, use: [AUTOBOOT_SD.md](AUTOBOOT_SD.md)

## Documentation

- Setup and architecture: [README.md](README.md)
- SD card deployment path: [SD_CARD_QUICKSTART.md](SD_CARD_QUICKSTART.md)
- Fully unattended SD prep: [AUTOBOOT_SD.md](AUTOBOOT_SD.md)
- Easiest operating model and tool choices: [WORKFLOW_CHOICES.md](WORKFLOW_CHOICES.md)
- Day-2 operations: [HOWTO.md](HOWTO.md)
- Release runbook: [RELEASE.md](RELEASE.md)
- Release history: [CHANGELOG.md](CHANGELOG.md)
- Current release version: [VERSION](VERSION)

## Practical recommendation

If your goal is the easiest reliable workflow, use:
1. Raspberry Pi Imager to create the SD card.
2. Unattended prep script from [AUTOBOOT_SD.md](AUTOBOOT_SD.md).
3. Docker stack in this repo (no Home Assistant required).

Use Home Assistant only as an optional dashboard later.

The Pi runs two containers:
- `kiwix-server`: serves all `.zim` files in `./zim_data`.
- `kiwix-sync-agent`: checks your GitHub-hosted `zimlist.txt`, downloads new torrents with resume support, then restarts Kiwix.

## Why this pattern works

- Zero routine SSH maintenance after initial setup.
- Library state lives in Git (simple to audit and update).
- Interrupted large downloads resume automatically with `aria2c`.

## Files in this repo

- `docker-compose.yml`: two-service stack.
- `scripts/sync.sh`: sidecar loop that polls GitHub and syncs changes.
- `.env.example`: environment values to copy into `.env`.
- `zimlist.txt.example`: starter format for your torrent list.
- `profiles/medical-survival-zimlist.txt`: recommended baseline list for emergency readiness.
- `zim_data/`: persistent data folder for downloaded `.zim` files and current `zimlist.txt`.

## One-time setup

1. Create a private GitHub repo with a `zimlist.txt` file.
2. Add one torrent permalink per line in `zimlist.txt`.
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

## Fastest first-boot path

If you use Raspberry Pi Imager Advanced Options, you can run a script at first boot so the Pi auto-installs Docker and starts this stack:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<branch>/scripts/bootstrap-pi.sh | sudo bash
```

See [SD_CARD_QUICKSTART.md](SD_CARD_QUICKSTART.md) for exact steps.

## Updating content later

1. Edit `zimlist.txt` in GitHub (phone or PC).
2. Commit changes.
3. The sidecar detects changes on the next poll and syncs automatically.

Set `SYNC_INTERVAL_SECONDS` in `.env` to tune check frequency. Default is `86400` (24h).

## Recommended baseline content

The included medical-survival profile prioritizes:
- Medical reference for non-clinicians and clinicians (`mdwiki`, `wikem`).
- Disaster and wilderness readiness (`ready.gov`, `survivalmanual`).
- Repair/recovery content (`ifixit`, selected Stack Exchange archives).
- Broad reference (`wikipedia_en_all_nopic`, `wikipedia_nl_all_nopic`).

## Versioning and releases

- Versioning follows Semantic Versioning (`MAJOR.MINOR.PATCH`).
- The authoritative current version is stored in [VERSION](VERSION).
- Every user-visible change should be recorded in [CHANGELOG.md](CHANGELOG.md) under `Unreleased`, then moved to a dated release section.

## Safety notes

- This setup mounts `/var/run/docker.sock` in the sidecar so it can restart `kiwix-server`.
- Keep this Pi trusted and avoid running untrusted containers alongside this stack.
- Never commit `.env` (it may contain your token).
- Prefer `GITHUB_TOKEN_FILE` over `GITHUB_TOKEN` so tokens are read from a file instead of env values.

## Troubleshooting

- Check logs:

```bash
docker compose logs -f kiwix-sync-agent
docker compose logs -f kiwix-server
```

- Force a manual sync test by temporarily setting `SYNC_INTERVAL_SECONDS=60`, then restart the sync container:

```bash
docker compose restart kiwix-sync-agent
```
