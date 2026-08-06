param(
  [Parameter(Mandatory = $true)]
  [string]$Version
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
  throw "Version must match MAJOR.MINOR.PATCH"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionFile = Join-Path $repoRoot "VERSION"
$changelogFile = Join-Path $repoRoot "CHANGELOG.md"

$today = Get-Date -Format "yyyy-MM-dd"
$changelog = Get-Content $changelogFile -Raw

if ($changelog -match "(?m)^## \[$Version\]") {
  throw "CHANGELOG already has section for $Version"
}

$releasedSection = @"
## [$Version] - $today

### Changed
- Describe user-visible changes here.

"@

if ($changelog -notmatch '(?m)^## \[Unreleased\]\s*$') {
  throw "CHANGELOG.md must contain ## [Unreleased]"
}

$updated = [regex]::Replace(
  $changelog,
  '(?m)^## \[Unreleased\]\s*$',
  "## [Unreleased]`r`n`r`n$releasedSection"
)

Set-Content -Path $versionFile -Value $Version -NoNewline
Set-Content -Path $changelogFile -Value $updated

Write-Host "Updated VERSION to $Version"
Write-Host "Inserted release section in CHANGELOG.md"
Write-Host "Next steps:"
Write-Host "  1) Fill in the release notes section"
Write-Host "  2) git add VERSION CHANGELOG.md"
Write-Host "  3) git commit -m \"release: v$Version\""
Write-Host "  4) git tag v$Version"
Write-Host "  5) git push && git push --tags"
