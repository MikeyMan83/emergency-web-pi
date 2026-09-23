param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [Parameter(Mandatory = $true)]
  [int]$ConfirmDiskNumber,

  [string]$BaseImagePath = "",

  [string]$BaseConfigPath = "config/appliance.example.json",

  [string]$ProfilePath = "profiles/medical-survival-zimlist.txt",

  [string]$CacheDir = "artifacts/zim-cache",

  [ValidateSet("FirstBoot", "Prebuilt")]
  [string]$ContentMode = "FirstBoot",

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

if ([string]::IsNullOrWhiteSpace($BaseImagePath)) {
  throw "Base image path is required. Provide a local Raspberry Pi OS Lite image with -BaseImagePath."
}

$resolvedBaseImage = (Resolve-Path $BaseImagePath).Path
$resolvedBaseConfig = (Resolve-Path $BaseConfigPath).Path
$resolvedProfile = (Resolve-Path $ProfilePath).Path
$resolvedCacheDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $CacheDir))
$resolvedConfigPath = Join-Path $repoRoot "artifacts/dynamic-appliance-config.json"
$stageDir = Join-Path $repoRoot "artifacts/dynamic-zim-stage"
$outputImagePath = Join-Path $repoRoot "artifacts/dynamic-appliance.img"
$outputManifestPath = "$outputImagePath.manifest.json"

$urls = Read-ProfileEntries -Path $resolvedProfile
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
  "-ZimSourceDir", $stageDir
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
if ($ContentMode -eq "Prebuilt") {
  Write-Host "Content:    $($selectedNames.Count) ZIM files embedded in ext4 zimdata"
} else {
  Write-Host "Content:    $($selectedNames.Count) selected ZIM files will download on first boot"
}
Write-Host "Next: safely eject SD card and boot the Pi."
