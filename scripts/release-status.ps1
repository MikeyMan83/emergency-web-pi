param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$Repo = "MikeyMan83/emergency-web-pi"
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must use MAJOR.MINOR.PATCH format."
}

$tag = "v$Version"
$headers = @{ "User-Agent" = "EmergencyWebPi-release-status" }
$releaseUrl = "https://api.github.com/repos/$Repo/releases/tags/$tag"

try {
  $release = Invoke-RestMethod -Headers $headers -Uri $releaseUrl
} catch {
  Write-Output "PENDING: $tag has no published release record yet."
  exit 2
}

try {
  $latest = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest"
  $isLatest = $latest.tag_name -eq $tag
} catch {
  Write-Output "PENDING: GitHub did not return a latest release record for $tag."
  exit 2
}

$expectedAssets = @(
  "EmergencyWebPi-$Version-windows.zip",
  "EmergencyWebPi-$Version-windows.sha256.txt"
)
$actualAssets = @($release.assets | ForEach-Object { $_.name })
$missingAssets = @($expectedAssets | Where-Object { $_ -notin $actualAssets })

if ($release.draft -or -not $isLatest -or $missingAssets.Count -gt 0) {
  $reasons = @()
  if ($release.draft) { $reasons += "release is still a draft" }
  if (-not $isLatest) { $reasons += "release is not marked latest" }
  if ($missingAssets.Count -gt 0) { $reasons += "missing assets: $($missingAssets -join ', ')" }
  Write-Output "PENDING: $tag is not published and complete ($($reasons -join '; '))."
  exit 2
}

Write-Output "PUBLISHED: $tag is latest with both Windows release assets."