# Workflow Choices (Drop-Dead Easiest Path)

This project supports multiple ways to operate, but one path is clearly simplest.

## Recommended default (simplest)

Use Docker on the Pi with Raspberry Pi Imager plus a `firstrun.sh` file in the boot partition.

Why:
- One stack to maintain.
- No custom desktop app needed.
- No Home Assistant dependency.
- No low-level SD scripting required.
- No manual SSH deploy step required.
- Easy to recover: reflash SD, boot, done.

## What to use for SD card creation

Use Raspberry Pi Imager, not Rufus, for this project.

Why Pi Imager is better here:
- It supports Advanced Options (SSH, Wi-Fi, user, first-boot command).
- It prepares SSH and network so first boot can self-provision.
- It reduces manual post-flash steps to near zero.

Rufus is fine for raw imaging, but you lose first-boot automation convenience.

Advanced optional path: unattended setup in `AUTOBOOT_SD.md`.

## Home Assistant as frontend?

Possible, but not the easiest baseline.

Use Home Assistant only if you already run it daily and want:
- a dashboard button to trigger sync checks,
- status cards for download progress,
- notifications when new content finishes.

Otherwise, skip it. The GitHub + sidecar flow already gives low-friction updates.

## Practical operating model

1. Keep this repo as your source of truth.
2. Keep content list in one file (`profiles/medical-survival-zimlist.txt` or your own `zimlist.txt`).
3. Flash card with Pi Imager and enable SSH/Wi-Fi.
4. Add `firstrun.sh` to the SD `boot` partition.
5. Boot Pi once and let first-boot automation run.
6. Edit content list from phone or PC; Pi updates itself.

Offline-first note: if GitHub is unreachable, existing local `.zim` files remain fully available.

## 10-minute disaster recovery

If SD card dies:
1. Flash a fresh card with Pi Imager.
2. Add the same `firstrun.sh` file.
3. Boot Pi on internet.
4. Stack rebuilds itself and re-downloads content.
