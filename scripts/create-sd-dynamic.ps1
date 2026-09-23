param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [Parameter(Mandatory = $true)]
  [int]$ConfirmDiskNumber,

  [Parameter(Mandatory = $true)]
  [string]$BaseImagePath,

  [Parameter(Mandatory = $true)]
  [string]$BaseManifestPath,

  [string]$BaseConfigPath = "config/appliance.example.json",

  [string]$ProfilePath = "profiles/medical-survival-zimlist.txt",

  [string]$CacheDir = "artifacts/zim-cache",

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

function New-ZimDataPartition {
  param([Parameter(Mandatory = $true)][int]$TargetDiskNumber)

  $existingZim = Get-Partition -DiskNumber $TargetDiskNumber -ErrorAction SilentlyContinue |
    Where-Object {
      try {
        $vol = Get-Volume -Partition $_ -ErrorAction Stop
        $vol.FileSystemLabel -eq "ZIMDATA"
      } catch {
        $false
      }
    }

  if ($existingZim) {
    $p = $existingZim | Select-Object -First 1
    $v = Get-Volume -Partition $p
    if ($v.DriveLetter) {
      return "{0}:\" -f $v.DriveLetter
    }
  }

  $newPart = New-Partition -DiskNumber $TargetDiskNumber -UseMaximumSize -AssignDriveLetter
  $formatted = Format-Volume -Partition $newPart -FileSystem exFAT -NewFileSystemLabel "ZIMDATA" -Confirm:$false
  if (-not $formatted.DriveLetter) {
    throw "Failed to assign drive letter for new ZIMDATA partition."
  }

  return "{0}:\" -f $formatted.DriveLetter
}

Require-Admin

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$resolvedBaseImage = (Resolve-Path $BaseImagePath).Path
$resolvedBaseManifest = (Resolve-Path $BaseManifestPath).Path
$resolvedBaseConfig = (Resolve-Path $BaseConfigPath).Path
$resolvedProfile = (Resolve-Path $ProfilePath).Path
$resolvedCacheDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $CacheDir))

$urls = Read-ProfileEntries -Path $resolvedProfile
Require-Aria2

if (-not (Test-Path $resolvedCacheDir)) {
  New-Item -ItemType Directory -Path $resolvedCacheDir | Out-Null
}

Write-Host "Flashing base image to disk #$DiskNumber"
$createSdArgs = @(
  "-DiskNumber", $DiskNumber,
  "-ConfirmDiskNumber", $ConfirmDiskNumber,
  "-ConfigPath", $resolvedBaseConfig,
  "-ImagePath", $resolvedBaseImage,
  "-ManifestPath", $resolvedBaseManifest,
  "-Force"
)
if ($AllowFixedDisk) {
  $createSdArgs += "-AllowFixedDisk"
}

& "$repoRoot\scripts\create-sd.ps1" @createSdArgs
if ($LASTEXITCODE -ne 0) {
  throw "Base image flash failed."
}

Write-Host "Preparing ZIMDATA exFAT partition on disk #$DiskNumber"
$zimDrive = New-ZimDataPartition -TargetDiskNumber $DiskNumber
Write-Host "ZIMDATA mounted at $zimDrive"

$selectedNames = @()
foreach ($url in $urls) {
  $name = Resolve-ZimFileName -Url $url
  $target = Join-Path $resolvedCacheDir $name

  if (Test-Path $target -PathType Leaf) {
    $len = (Get-Item $target).Length
    if ($len -gt 0) {
      Write-Host "Using cached: $name"
      $selectedNames += $name
      continue
    }
  }

  Write-Host "Downloading: $name"
  Invoke-AriaDownload -Url $url -TargetDir $resolvedCacheDir -OutputName $name
  $selectedNames += $name
}

Write-Host "Copying selected ZIM files to SD card"
foreach ($name in $selectedNames) {
  $source = Join-Path $resolvedCacheDir $name
  $dest = Join-Path $zimDrive $name
  Copy-Item -Path $source -Destination $dest -Force
}

Copy-Item -Path $resolvedProfile -Destination (Join-Path $zimDrive "zimlist.txt") -Force

$stampPath = Join-Path $zimDrive "BUILD_INFO.txt"
@(
  "Generated: $(Get-Date -Format o)",
  "Profile: $resolvedProfile",
  "Entries: $($selectedNames.Count)"
) | Set-Content -Path $stampPath -Encoding utf8

Write-Host ""
Write-Host "Dynamic SD build complete"
Write-Host "Disk:       #$DiskNumber"
Write-Host "ZIMDATA:    $zimDrive"
Write-Host "ZIM files:  $($selectedNames.Count)"
Write-Host "Next: safely eject SD card and boot the Pi."
