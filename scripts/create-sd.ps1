param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [string]$ConfigPath = "config/appliance.example.json",

  [string]$ImagePath = "",

  [string]$ManifestPath = "",

  [string]$ResolvedConfigPath = "config/appliance.local.json",

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Require-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "create-sd.ps1 must be run from an elevated PowerShell session."
  }
}

function Read-Config {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    throw "Config file not found: $Path"
  }

  try {
    return Get-Content $Path -Raw | ConvertFrom-Json
  } catch {
    throw "Config file is not valid JSON: $Path"
  }
}

function Require-Value {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($null -eq $Value) {
    throw $Message
  }

  if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
    throw $Message
  }
}

function Validate-Config {
  param($Config)

  Require-Value $Config.applianceVersion "Config must set applianceVersion."
  Require-Value $Config.content.profile "Config must set content.profile."
  Require-Value $Config.content.snapshot "Config must set content.snapshot."
  Require-Value $Config.network.ap.ssid "Config must set network.ap.ssid."
  Require-Value $Config.network.ap.password "Config must set network.ap.password."
  Require-Value $Config.network.ap.address "Config must set network.ap.address."
  Require-Value $Config.network.ap.port "Config must set network.ap.port."
  Require-Value $Config.system.hostname "Config must set system.hostname."

  if ($Config.network.ap.password.Length -lt 8) {
    throw "network.ap.password must be at least 8 characters."
  }

  if ($Config.updates.intervalSeconds -lt 0) {
    throw "updates.intervalSeconds must be 0 or greater."
  }
}

function New-ApPassword {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%*+-_'
  $bytes = New-Object byte[] 20
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) {
    [void]$sb.Append($chars[$b % $chars.Length])
  }
  return $sb.ToString()
}

function Resolve-ApPassword {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$ResolvedConfigPath
  )

  $needsGenerated = $Config.network.ap.password -eq "__GENERATE__" -or
                    $Config.network.ap.password -eq "ChangeThisEmergencyPassword123"

  if (-not $needsGenerated) {
    return
  }

  $generated = New-ApPassword
  $Config.network.ap.password = $generated

  $resolvedDir = Split-Path -Parent $ResolvedConfigPath
  if (-not [string]::IsNullOrWhiteSpace($resolvedDir) -and -not (Test-Path $resolvedDir)) {
    New-Item -ItemType Directory -Path $resolvedDir | Out-Null
  }

  ($Config | ConvertTo-Json -Depth 10) + "`n" | Set-Content -Path $ResolvedConfigPath -Encoding utf8

  Write-Host "Generated AP password and wrote resolved config: $ResolvedConfigPath"
  if ($ConfigPath -eq "config/appliance.example.json") {
    Write-Host "Using generated credentials from resolved config for this run."
  }
}

function Get-TargetDisk {
  param([int]$Number)

  $disk = Get-Disk -Number $Number -ErrorAction Stop
  if ($disk.BusType -eq "USB" -or $disk.BusType -eq "SD") {
    return $disk
  }

  Write-Warning "Disk $Number is bus type '$($disk.BusType)'. Double-check you selected the removable SD target."
  return $disk
}

function Resolve-ImagePath {
  param([string]$ProvidedImagePath)

  if (-not [string]::IsNullOrWhiteSpace($ProvidedImagePath)) {
    if (-not (Test-Path $ProvidedImagePath)) {
      throw "Image artifact not found: $ProvidedImagePath"
    }
    return (Resolve-Path $ProvidedImagePath).Path
  }

  $candidates = @(
    "artifacts/appliance.img",
    "artifacts/pi-kiwix-survival.img",
    "appliance.img"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return (Resolve-Path $candidate).Path
    }
  }

  $imgFiles = @(Get-ChildItem -Path "artifacts" -Filter "*.img" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if ($imgFiles.Count -gt 0) {
    return $imgFiles[0].FullName
  }

  throw "No appliance image found. Provide -ImagePath or place a .img file in artifacts/."
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  $hash = Get-FileHash -Path $Path -Algorithm SHA256
  return $hash.Hash.ToLowerInvariant()
}

function Resolve-ManifestPath {
  param(
    [Parameter(Mandatory = $true)][string]$ResolvedImagePath,
    [string]$ProvidedManifestPath
  )

  if (-not [string]::IsNullOrWhiteSpace($ProvidedManifestPath)) {
    if (-not (Test-Path $ProvidedManifestPath)) {
      throw "Manifest file not found: $ProvidedManifestPath"
    }
    return (Resolve-Path $ProvidedManifestPath).Path
  }

  $direct = "$ResolvedImagePath.manifest.json"
  if (Test-Path $direct) {
    return (Resolve-Path $direct).Path
  }

  $imageName = [System.IO.Path]::GetFileName($ResolvedImagePath)
  $sibling = Join-Path ([System.IO.Path]::GetDirectoryName($ResolvedImagePath)) "$imageName.manifest.json"
  if (Test-Path $sibling) {
    return (Resolve-Path $sibling).Path
  }

  throw "No image manifest found. Provide -ManifestPath or add '$imageName.manifest.json' next to the image."
}

function Read-Manifest {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    return Get-Content $Path -Raw | ConvertFrom-Json
  } catch {
    throw "Manifest file is not valid JSON: $Path"
  }
}

function Validate-Manifest {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)][string]$ResolvedImagePath
  )

  Require-Value $Manifest.schemaVersion "Manifest must set schemaVersion."
  Require-Value $Manifest.applianceVersion "Manifest must set applianceVersion."
  Require-Value $Manifest.image.sha256 "Manifest must set image.sha256."
  Require-Value $Manifest.storage.partitions "Manifest must set storage.partitions."
  Require-Value $Manifest.runtime.serverMode "Manifest must set runtime.serverMode."
  Require-Value $Manifest.runtime.overlayRootEnabled "Manifest must set runtime.overlayRootEnabled."
  Require-Value $Manifest.runtime.zimDataOnDedicatedPartition "Manifest must set runtime.zimDataOnDedicatedPartition."

  $partitionNames = @($Manifest.storage.partitions | ForEach-Object { $_.name.ToString().ToLowerInvariant() })
  if ($partitionNames -notcontains "boot") {
    throw "Manifest storage.partitions must include a 'boot' partition."
  }
  if ($partitionNames -notcontains "root") {
    throw "Manifest storage.partitions must include a 'root' partition."
  }
  if ($partitionNames -notcontains "zimdata") {
    throw "Manifest storage.partitions must include a dedicated 'zimdata' partition."
  }

  $serverMode = $Manifest.runtime.serverMode.ToString().ToLowerInvariant()
  if ($serverMode -ne "native-kiwix-serve") {
    throw "Manifest runtime.serverMode must be native-kiwix-serve."
  }

  if (-not [bool]$Manifest.runtime.zimDataOnDedicatedPartition) {
    throw "Manifest indicates ZIM data is not on a dedicated partition. This image is rejected."
  }

  $overlayEnabled = [bool]$Manifest.runtime.overlayRootEnabled
  $dockerDriver = "none"
  if ($null -ne $Manifest.runtime.docker -and $null -ne $Manifest.runtime.docker.storageDriver) {
    $dockerDriver = $Manifest.runtime.docker.storageDriver.ToString().ToLowerInvariant()
  }
  if ($overlayEnabled -and $dockerDriver -eq "overlay2") {
    throw "Manifest indicates root overlayfs with Docker overlay2. This nested-overlay combination is rejected."
  }

  $actual = Get-FileSha256 -Path $ResolvedImagePath
  $expected = $Manifest.image.sha256.ToString().ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "Image SHA256 does not match manifest. expected=$expected actual=$actual"
  }
}

function Confirm-ImageFitsDisk {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)]$Disk
  )

  $imageSize = (Get-Item $ImagePath).Length
  if ($imageSize -gt $Disk.Size) {
    throw "Image size ($([math]::Round($imageSize / 1GB, 2)) GB) exceeds disk size ($([math]::Round($Disk.Size / 1GB, 2)) GB)."
  }
}

function Unmount-DiskVolumes {
  param([int]$DiskNumber)

  $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
  foreach ($partition in $partitions) {
    if ($partition.DriveLetter) {
      $drive = "{0}:" -f $partition.DriveLetter
      try {
        mountvol $drive /p | Out-Null
      } catch {
        Write-Warning "Could not dismount $drive cleanly. Continuing."
      }
    }
  }
}

function Get-PartialHash {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][Int64]$BytesToHash
  )

  $hasher = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $buffer = New-Object byte[] (4MB)
    [Int64]$remaining = $BytesToHash
    while ($remaining -gt 0) {
      $toRead = [Math]::Min($buffer.Length, $remaining)
      $read = $stream.Read($buffer, 0, [int]$toRead)
      if ($read -le 0) { break }
      [void]$hasher.TransformBlock($buffer, 0, $read, $null, 0)
      $remaining -= $read
    }
    [void]$hasher.TransformFinalBlock(@(), 0, 0)
    return ([BitConverter]::ToString($hasher.Hash)).Replace("-", "").ToLowerInvariant()
  } finally {
    $stream.Dispose()
    $hasher.Dispose()
  }
}

function Write-ImageToDisk {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [Parameter(Mandatory = $true)]$Disk
  )

  Confirm-ImageFitsDisk -ImagePath $ImagePath -Disk $Disk
  Unmount-DiskVolumes -DiskNumber $DiskNumber

  try {
    Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null
  } catch {
    Write-Warning "Could not clear read-only flag on disk $DiskNumber before write."
  }

  $targetPath = "\\.\PhysicalDrive$DiskNumber"
  $source = [System.IO.File]::Open($ImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  $target = New-Object System.IO.FileStream($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)

  try {
    $buffer = New-Object byte[] (4MB)
    [Int64]$totalBytes = $source.Length
    [Int64]$written = 0
    $lastPercent = -1

    while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $target.Write($buffer, 0, $read)
      $written += $read

      $percent = [int](($written * 100) / $totalBytes)
      if ($percent -ne $lastPercent) {
        Write-Progress -Activity "Writing appliance image" -Status "$percent%" -PercentComplete $percent
        $lastPercent = $percent
      }
    }

    $target.Flush($true)
    Write-Progress -Activity "Writing appliance image" -Completed
  } finally {
    $source.Dispose()
    $target.Dispose()
  }

  $verifyBytes = [Math]::Min((Get-Item $ImagePath).Length, 8MB)
  $imageHash = Get-PartialHash -Path $ImagePath -BytesToHash $verifyBytes
  $diskHash = Get-PartialHash -Path $targetPath -BytesToHash $verifyBytes
  if ($imageHash -ne $diskHash) {
    throw "Post-write verification failed: disk prefix hash does not match image prefix hash."
  }
}

Require-Admin

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$config = Read-Config -Path $ConfigPath
Validate-Config -Config $config
Resolve-ApPassword -Config $config -ConfigPath $ConfigPath -ResolvedConfigPath $ResolvedConfigPath

$disk = Get-TargetDisk -Number $DiskNumber

$minimumBytes = 90GB
if ($disk.Size -lt $minimumBytes) {
  throw "Disk $DiskNumber is too small. Need at least $([math]::Round($minimumBytes / 1GB)) GB for the current appliance target."
}

Write-Host "Pi Kiwix Survival Builder"
Write-Host ""
Write-Host "Disk:              #$DiskNumber ($([math]::Round($disk.Size / 1GB, 2)) GB)"
Write-Host "Appliance version: $($config.applianceVersion)"
Write-Host "Content profile:   $($config.content.profile)"
Write-Host "Content snapshot:  $($config.content.snapshot)"
Write-Host "Emergency SSID:    $($config.network.ap.ssid)"
Write-Host "Emergency URL:     http://$($config.network.ap.address):$($config.network.ap.port)"

if ($config.network.upstream.enabled) {
  Write-Host "Upstream Wi-Fi:    enabled"
} else {
  Write-Host "Upstream Wi-Fi:    disabled"
}

$resolvedImagePath = Resolve-ImagePath -ProvidedImagePath $ImagePath
$resolvedManifestPath = Resolve-ManifestPath -ResolvedImagePath $resolvedImagePath -ProvidedManifestPath $ManifestPath
$manifest = Read-Manifest -Path $resolvedManifestPath
Validate-Manifest -Manifest $manifest -ResolvedImagePath $resolvedImagePath

Write-Host "Image:             $resolvedImagePath"
Write-Host "Manifest:          $resolvedManifestPath"

if (-not $Force) {
  Write-Warning "Image writing is destructive. Re-run with -Force to write the appliance image to disk #$DiskNumber."
  return
}

Write-Host ""
Write-Host "Writing appliance image to disk #$DiskNumber ..."
Write-ImageToDisk -ImagePath $resolvedImagePath -DiskNumber $DiskNumber -Disk $disk

Write-Host ""
Write-Host "Build successful"
Write-Host "Emergency Wi-Fi"
Write-Host "SSID:     $($config.network.ap.ssid)"
Write-Host "Password: $($config.network.ap.password)"
Write-Host "Kiwix:    http://$($config.network.ap.address):$($config.network.ap.port)"