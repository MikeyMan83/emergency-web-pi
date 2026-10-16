param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$Repo = "MikeyMan83/emergency-web-pi",

  # Optional GitHub token. Required to check a PRIVATE repository when the
  # machine has no other GitHub credentials: without authorization the GitHub
  # API answers 404 for private repos, which is indistinguishable from a
  # missing release.
  [string]$Token = ""
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must use MAJOR.MINOR.PATCH format."
}

$tag = "v$Version"
$headers = @{ "User-Agent" = "EmergencyWebPi-release-status" }
if (-not [string]::IsNullOrWhiteSpace($Token)) {
  $headers["Authorization"] = "Bearer $Token"
}
$releaseUrl = "https://api.github.com/repos/$Repo/releases/tags/$tag"

try {
  $release = Invoke-RestMethod -Headers $headers -Uri $releaseUrl
} catch {
  $statusCode = 0
  try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
  if ($statusCode -eq 404 -and [string]::IsNullOrWhiteSpace($Token)) {
    Write-Output "INDETERMINATE: GitHub returned 404 for $Repo. This is expected for a private repository checked without -Token (or a wrong repository name). Re-run with -Token <GitHub PAT>."
    exit 2
  }
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