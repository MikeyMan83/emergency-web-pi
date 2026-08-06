# SD Card Quickstart (RPi 3B+)

This is the shortest path to a grab-and-go offline Pi.

This is a zero-touch setup after power-on: flash, add one file, boot.

## What you need

- Raspberry Pi 3B+
- microSD card (32GB minimum, 128GB+ recommended)
- Ethernet or Wi-Fi on first boot
- A GitHub repo that contains `zimlist.txt`

## 1. Flash the card

1. Open Raspberry Pi Imager.
2. Choose OS: `Raspberry Pi OS Lite (64-bit)`.
3. Choose Storage: your microSD.
4. Open Advanced Options (gear icon):
   - Set hostname (example: `kiwixpi`).
   - Enable SSH.
   - Set username/password.
   - Configure Wi-Fi if needed.
   - Set locale/timezone.
5. Write the card.

## 2. Add first-boot automation file

1. Reinsert the SD card into your PC after flashing.
2. Open the `boot` partition.
3. Create a file named `firstrun.sh`.
4. Paste this content:

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

You can also copy from [firstrun.sh.example](firstrun.sh.example).

## 3. First boot

1. Insert SD card and boot Pi.
2. Wait for first boot provisioning to finish.
3. Open in browser:

```text
http://kiwixpi.local:8080
```

If `.local` does not resolve, use the Pi IP from your router.

## 4. How it behaves offline

- If internet exists: sync agent checks GitHub and downloads updates.
- If internet is down: sync agent skips update and retries later.
- Existing local library still serves normally from `zim_data/`.

## 5. Add or update content later

1. Edit `zimlist.txt` in your GitHub repo.
2. Commit.
3. Pi sync agent pulls updates automatically at the configured interval.

Tip: for fastest initial deployment, set `GITHUB_URL` to the raw file for `profiles/medical-survival-zimlist.txt` in your repo.

## Optional: private repo token file (recommended)

Use this once after first boot to avoid token in env values:

```bash
ssh <user>@kiwixpi.local
cd ~/pi-kiwix-survival
mkdir -p secrets
printf '%s' '<YOUR_FINE_GRAINED_TOKEN>' > secrets/github_token
chmod 600 secrets/github_token
```

Then set in `.env`:

```dotenv
GITHUB_TOKEN_FILE=/run/secrets/github_token
GITHUB_TOKEN=
```

Restart stack:

```bash
docker compose up -d
```
