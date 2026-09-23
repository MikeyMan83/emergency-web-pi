# Release Process

This project publishes GitHub releases from git tags (`vMAJOR.MINOR.PATCH`).

## 1. Prepare release files

Run:

```powershell
./scripts/new-release.ps1 -Version <version>
```

Then edit `docs/CHANGELOG.md` and write the final release notes for this version.

## 2. Commit

```bash
git add docs/VERSION docs/CHANGELOG.md
git commit -m "release: v<version>"
```

## 3. Tag and push

```bash
git tag -a v<version> -m "Release v<version>"
git push
git push --tags
```

## 4. Automated release

The workflow at `.github/workflows/release.yml` will:
1. Verify `docs/VERSION` matches the pushed tag.
2. Verify `docs/CHANGELOG.md` includes the matching section.
3. Build the Windows bundle and checksum.
4. Create a draft GitHub Release using that changelog section.
5. Upload the bundle and checksum, then publish the release.

A pushed tag is not a published release until GitHub confirms a non-draft latest
release with both expected assets. Run this command before announcing publication:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/release-status.ps1 -Version <version>
```

It exits `0` only for a published, latest, asset-complete release. Exit `2` means
the tag is pushed but publication is still pending; do not describe it as released.

## End-user download artifact (current)

Release workflow now attaches a Windows portable bundle asset:

1. `EmergencyWebPi-<version>-windows.zip`
2. `EmergencyWebPi-<version>-windows.sha256.txt`

Bundle contents include:

1. Root frontend executable: `EmergencyWebPi.exe`
2. Root launcher: `Launch-EmergencyWebPi.cmd` (fallback/manual path)

Packaging now fails if EXE generation fails, so release bundles do not silently fall back to script-only startup.
