param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [Parameter(Mandatory = $true)]
  [int]$ConfirmDiskNumber,

  [string]$BaseImagePath = "",

  [string]$BaseManifestPath = "config/base-image.json",

  [string]$BaseImageCacheDir = "artifacts/base-image-cache",

  [string]$BaseConfigPath = "config/appliance.example.json",

  [string]$ProfilePath = "profiles/medical-survival-zimlist.txt",

  [string]$CacheDir = "artifacts/zim-cache",

  [string]$WorkspaceDir = "artifacts",

  [ValidateSet("FirstBoot", "Prebuilt")]
  [string]$ContentMode = "FirstBoot",

  [int]$MinZimPartitionGb = 8,

  [switch]$AllowFixedDisk
)

$ErrorActionPreference = "Stop"

function Require-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "create-sd-dynamic.ps1 must be run from an elevated PowerShell session."
  }
}

function Resolve-WorkspacePath {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
}

function Read-ProfileEntries {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "Profile file not found: $Path"
  }

  $urls = @()
  foreach ($line in Get-Content $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    $urls += $trimmed
  }

  if ($urls.Count -eq 0) {
    throw "Profile contains no download entries: $Path"
  }

  return $urls
}

function Get-RequiredZimPartitionGb {
  param(
    [Parameter(Mandatory = $true)][string[]]$Urls,
    [Parameter(Mandatory = $true)][int]$MinimumGb
  )

  $catalogPath = Join-Path $repoRoot "config/content-catalog.json"
  try {
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
  } catch {
    throw "Content catalog is not valid JSON: $catalogPath"
  }

  [int64]$contentBytes = 0
  foreach ($url in $Urls) {
    $fileName = Resolve-ZimFileName -Url $url
    $item = $catalog.PSObject.Properties[$fileName].Value
    if ($null -eq $item -or $item.estimatedBytes -le 0) {
      throw "Content catalog is missing a size estimate for: $fileName"
    }
    $contentBytes += [int64]$item.estimatedBytes
  }

  $requiredGb = [int][Math]::Ceiling(($contentBytes + 1GB) / 1GB)
  return [Math]::Max($MinimumGb, $requiredGb)
}

function Resolve-ZimFileName {
  param([Parameter(Mandatory = $true)][string]$Url)

  $name = [System.IO.Path]::GetFileName($Url)
  if ($name.EndsWith(".torrent", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $name.Substring(0, $name.Length - 8)
  }
  return $name
}

function Require-Aria2 {
  $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
  if (-not $cmd) {
    throw "aria2c is required for dynamic content download. Install aria2 and retry."
  }
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-BaseImage {
  param(
    [string]$ProvidedImagePath,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$CacheDir
  )

  if (-not [string]::IsNullOrWhiteSpace($ProvidedImagePath)) {
    if (-not (Test-Path $ProvidedImagePath)) {
      throw "Advanced base image override was not found: $ProvidedImagePath"
    }
    return (Resolve-Path $ProvidedImagePath).Path
  }

  if (-not (Test-Path $ManifestPath)) {
    throw "Pinned base-image manifest was not found: $ManifestPath"
  }

  try {
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
  } catch {
    throw "Pinned base-image manifest is not valid JSON: $ManifestPath"
  }

  foreach ($field in @("downloadUrl", "sha256")) {
    if ([string]::IsNullOrWhiteSpace($manifest.$field)) {
      throw "Pinned base-image manifest must set $field."
    }
  }

  $expectedHash = $manifest.sha256.ToString().ToLowerInvariant()
  if ($expectedHash -notmatch "^[0-9a-f]{64}$") {
    throw "Pinned base-image manifest sha256 is not a valid SHA-256 value."
  }

  $resolvedCacheDir = [System.IO.Path]::GetFullPath($CacheDir)
  New-Item -ItemType Directory -Path $resolvedCacheDir -Force | Out-Null
  $fileName = [System.IO.Path]::GetFileName(([Uri]$manifest.downloadUrl).AbsolutePath)
  if ([string]::IsNullOrWhiteSpace($fileName)) {
    throw "Pinned base-image manifest downloadUrl does not include a file name."
  }

  $imagePath = Join-Path $resolvedCacheDir $fileName
  if (Test-Path $imagePath) {
    if ((Get-FileSha256 -Path $imagePath) -eq $expectedHash) {
      Write-Host "Using verified Raspberry Pi OS image cache: $fileName"
      return $imagePath
    }
    Remove-Item -Force $imagePath
  }

  $temporaryPath = "$imagePath.download"
  Remove-Item -Force $temporaryPath -ErrorAction SilentlyContinue
  Write-Host "Downloading verified Raspberry Pi OS Lite image..."
  Invoke-WebRequest -Uri $manifest.downloadUrl -OutFile $temporaryPath -UseBasicParsing

  if ((Get-FileSha256 -Path $temporaryPath) -ne $expectedHash) {
    Remove-Item -Force $temporaryPath -ErrorAction SilentlyContinue
    throw "Downloaded Raspberry Pi OS image failed SHA-256 verification."
  }

  Move-Item -Path $temporaryPath -Destination $imagePath -Force
  Write-Host "Raspberry Pi OS image verified."
  return $imagePath
}

function Invoke-AriaDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OutputName
  )

  & aria2c -c --timeout=1800 --max-tries=3 --seed-time=0 -d $TargetDir -o $OutputName $Url
  if ($LASTEXITCODE -ne 0) {
    throw "Failed download: $Url"
  }
}

Require-Admin

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$resolvedBaseManifest = (Resolve-Path $BaseManifestPath).Path
$resolvedBaseImage = Resolve-BaseImage -ProvidedImagePath $BaseImagePath -ManifestPath $resolvedBaseManifest -CacheDir $BaseImageCacheDir
$resolvedBaseConfig = (Resolve-Path $BaseConfigPath).Path
$resolvedProfile = (Resolve-Path $ProfilePath).Path
$resolvedCacheDir = Resolve-WorkspacePath -PathValue $CacheDir
$resolvedWorkspaceDir = Resolve-WorkspacePath -PathValue $WorkspaceDir
New-Item -ItemType Directory -Path $resolvedWorkspaceDir -Force | Out-Null
$resolvedConfigPath = Join-Path $resolvedWorkspaceDir "dynamic-appliance-config.json"
$stageDir = Join-Path $resolvedWorkspaceDir "dynamic-zim-stage"
$outputImagePath = Join-Path $resolvedWorkspaceDir "dynamic-appliance.img"
$outputManifestPath = "$outputImagePath.manifest.json"

$urls = Read-ProfileEntries -Path $resolvedProfile
$effectiveZimPartitionGb = Get-RequiredZimPartitionGb -Urls $urls -MinimumGb $MinZimPartitionGb
if ($ContentMode -eq "Prebuilt") {
  Require-Aria2
}

if ($ContentMode -eq "Prebuilt" -and -not (Test-Path $resolvedCacheDir)) {
  New-Item -ItemType Directory -Path $resolvedCacheDir | Out-Null
}

$selectedNames = @()
foreach ($url in $urls) {
  $name = Resolve-ZimFileName -Url $url
  $selectedNames += $name

  if ($ContentMode -eq "FirstBoot") {
    continue
  }

  $target = Join-Path $resolvedCacheDir $name

  if (Test-Path $target -PathType Leaf) {
    $len = (Get-Item $target).Length
    if ($len -gt 0) {
      Write-Host "Using cached: $name"
      continue
    }
  }

  Write-Host "Downloading: $name"
  Invoke-AriaDownload -Url $url -TargetDir $resolvedCacheDir -OutputName $name
}

if (Test-Path $stageDir) {
  Remove-Item -Recurse -Force $stageDir
}
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
if ($ContentMode -eq "Prebuilt") {
  foreach ($name in $selectedNames) {
    Copy-Item -Path (Join-Path $resolvedCacheDir $name) -Destination (Join-Path $stageDir $name) -Force
  }
}
Copy-Item -Path $resolvedProfile -Destination (Join-Path $stageDir "zimlist.txt") -Force
Set-Content -Path (Join-Path $stageDir ".use_local_zimlist") -Value "1" -Encoding ascii
if ($ContentMode -eq "FirstBoot") {
  Set-Content -Path (Join-Path $stageDir ".content-install-pending") -Value "1" -Encoding ascii
}

$buildArgs = @(
  "-BaseImagePath", $resolvedBaseImage,
  "-ConfigPath", $resolvedBaseConfig,
  "-ResolvedConfigPath", $resolvedConfigPath,
  "-OutputImagePath", $outputImagePath,
  "-ManifestPath", $outputManifestPath,
  "-ZimSourceDir", $stageDir,
  "-MinZimPartitionGb", $effectiveZimPartitionGb
)
& "$repoRoot\scripts\build-appliance-image.ps1" @buildArgs
if ($LASTEXITCODE -ne 0) {
  throw "Appliance image build failed."
}

$createSdArgs = @(
  "-DiskNumber", $DiskNumber,
  "-ConfirmDiskNumber", $ConfirmDiskNumber,
  "-ConfigPath", $resolvedConfigPath,
  "-ImagePath", $outputImagePath,
  "-ManifestPath", $outputManifestPath,
  "-Force"
)
if ($AllowFixedDisk) {
  $createSdArgs += "-AllowFixedDisk"
}
& "$repoRoot\scripts\create-sd.ps1" @createSdArgs
if ($LASTEXITCODE -ne 0) {
  throw "Appliance image flash failed."
}

Write-Host ""
Write-Host "Dynamic SD build complete"
Write-Host "Disk:       #$DiskNumber"
Write-Host "ZIMDATA:    $effectiveZimPartitionGb GB ext4 partition"
if ($ContentMode -eq "Prebuilt") {
  Write-Host "Content:    $($selectedNames.Count) ZIM files embedded in ext4 zimdata"
} else {
  Write-Host "Content:    $($selectedNames.Count) selected ZIM files will download on first boot"
}
Write-Host "Next: safely eject SD card and boot the Pi."
