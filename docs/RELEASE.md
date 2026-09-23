# Release Process

This project publishes GitHub releases from git tags (`vMAJOR.MINOR.PATCH`).

## 1. Prepare release files

Run:

```powershell
./scripts/new-release.ps1 -Version 0.1.2
```

Then edit `docs/CHANGELOG.md` and write the final release notes for this version.

## 2. Commit

```bash
git add docs/VERSION docs/CHANGELOG.md
git commit -m "release: v0.1.2"
```

## 3. Tag and push

```bash
git tag v0.1.2
git push
git push --tags
```

## 4. Automated release

The workflow at `.github/workflows/release.yml` will:
1. Verify `docs/VERSION` matches the pushed tag.
2. Verify `docs/CHANGELOG.md` includes the matching section.
3. Publish a GitHub Release using that changelog section.

## End-user download artifact (current)

Release workflow now attaches a Windows portable bundle asset:

1. `PiKiwixPortable-<version>-windows.zip`
2. `PiKiwixPortable-<version>-windows.sha256.txt`

Bundle contents include:

1. Root launcher: `Launch-PiKiwixPortable.cmd`
2. Frontend: `portable/PiKiwixPortable.exe` when PS-to-EXE packaging succeeds, with script fallback.

If packaging fails in CI for any reason, users can still use `Source code (zip)` and run the root launcher.
