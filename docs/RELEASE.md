# Release Process

This project publishes GitHub releases from git tags (`vMAJOR.MINOR.PATCH`).

## 1. Prepare release files

Run:

```powershell
./scripts/new-release.ps1 -Version 0.1.2
```

Then edit `docs/CHANGELOG.md` and replace placeholder bullet points with real notes.

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
