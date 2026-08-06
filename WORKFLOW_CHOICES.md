# Workflow Choices (Drop-Dead Easiest Path)

This project supports multiple ways to operate, but one path is clearly simplest.

## Recommended default (simplest)

Use Docker on the Pi with Raspberry Pi Imager first-boot automation.
Best variant: prepare the boot partition with `scripts/prepare-sd-autoboot.ps1`.

Why:
- One stack to maintain.
- No custom desktop app needed.
- No Home Assistant dependency.
- Easy to recover: reflash SD, boot, done.

## What to use for SD card creation

Use Raspberry Pi Imager, not Rufus, for this project.

Why Pi Imager is better here:
- It supports Advanced Options (SSH, Wi-Fi, user, first-boot command).
- It can run bootstrap command on first boot.
- It reduces manual post-flash steps to near zero.

Rufus is fine for raw imaging, but you lose first-boot automation convenience.

For unattended setup details, see `AUTOBOOT_SD.md`.

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
3. Flash card with Pi Imager and first-boot command.
4. Boot Pi and let bootstrap install/start everything.
5. Edit content list from phone or PC; Pi updates itself.

## 10-minute disaster recovery

If SD card dies:
1. Flash a fresh card with Pi Imager.
2. Use same first-boot command.
3. Boot Pi on internet.
4. Stack rebuilds itself and re-downloads content.
