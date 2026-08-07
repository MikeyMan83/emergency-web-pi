param(
  [Parameter(Mandatory = $true)]
  [string]$Version
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
  throw "Version must match MAJOR.MINOR.PATCH"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionFile = Join-Path $repoRoot "docs\VERSION"
$changelogFile = Join-Path $repoRoot "docs\CHANGELOG.md"

$today = Get-Date -Format "yyyy-MM-dd"
$changelog = Get-Content $changelogFile -Raw

if ($changelog -match "(?m)^## \[$Version\]") {
  throw "CHANGELOG already has section for $Version"
}

$releasedSection = @"
## [$Version] - $today

### Changed
- Add final user-visible release notes.

"@

if ($changelog -notmatch '(?m)^## \[Unreleased\]\s*$') {
  throw "docs/CHANGELOG.md must contain ## [Unreleased]"
}

$updated = [regex]::Replace(
  $changelog,
  '(?m)^## \[Unreleased\]\s*$',
  "## [Unreleased]`r`n`r`n$releasedSection"
)

Set-Content -Path $versionFile -Value $Version -NoNewline
Set-Content -Path $changelogFile -Value $updated

Write-Host "Updated VERSION to $Version"
Write-Host "Inserted release section in docs/CHANGELOG.md"
Write-Host "Continue with release steps in docs/RELEASE.md"
