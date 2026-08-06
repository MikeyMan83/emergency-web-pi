# pi-kiwix-survival

HACS-style GitOps workflow for an offline-ready Raspberry Pi Kiwix library.

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
   - If your repo is private, set `GITHUB_TOKEN` to a fine-grained token with read-only Contents access.
6. Start the stack:

```bash
docker compose up -d
```

7. Open Kiwix at `http://<pi-ip>:8080`.

## Updating content later

1. Edit `zimlist.txt` in GitHub (phone or PC).
2. Commit changes.
3. The sidecar detects changes on the next poll and syncs automatically.

Set `SYNC_INTERVAL_SECONDS` in `.env` to tune check frequency. Default is `86400` (24h).

## Safety notes

- This setup mounts `/var/run/docker.sock` in the sidecar so it can restart `kiwix-server`.
- Keep this Pi trusted and avoid running untrusted containers alongside this stack.
- Never commit `.env` (it may contain your token).

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
