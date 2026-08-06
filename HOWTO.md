# How-To Operations Guide

This page is for routine operations after the Pi is deployed.

## First bring-up

1. Copy `.env.example` to `.env`.
2. Set `GITHUB_URL`.
3. For private repos, create `secrets/github_token` and set `GITHUB_TOKEN_FILE=/run/secrets/github_token`.
4. Start services:

```bash
docker compose up -d
```

## Verify health

```bash
docker compose ps
docker compose logs --tail=100 kiwix-sync-agent
docker compose logs --tail=100 kiwix-server
```

Expected:
- `kiwix-sync-agent` logs periodic "Checking GitHub for updates...".
- `kiwix-server` is running and reachable on port `8080`.

## Force an immediate content refresh

```bash
docker compose restart kiwix-sync-agent
docker compose logs -f kiwix-sync-agent
```

## Update software stack

```bash
git pull --ff-only
docker compose pull
docker compose up -d
```

## Backup important local data

Back up these paths:
- `zim_data/` (all downloaded knowledge files)
- `.env` (configuration)
- `secrets/github_token` (if used)

## Change sync frequency

Edit `.env`:

```dotenv
SYNC_INTERVAL_SECONDS=86400
```

Apply changes:

```bash
docker compose up -d
```

## Common recovery actions

If the sync agent cannot download list:
1. Confirm `GITHUB_URL` is correct.
2. Confirm token file exists and is readable if repo is private.
3. Check outbound internet on the Pi.

If Kiwix UI is empty:
1. Confirm `.zim` files exist under `zim_data/`.
2. Restart server:

```bash
docker compose restart kiwix-server
```
