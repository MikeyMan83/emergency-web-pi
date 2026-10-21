param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [Parameter(Mandatory = $true)]
  [int]$ConfirmDiskNumber,

  # Base image asset (.img.gz, first split part, or raw .img). Empty = download from the release.
  [string]$ImagePath = "",

  # ewp-base-<version>.img.manifest.json. Defaults to the file next to -ImagePath or the downloaded one.
  [string]$ManifestPath = "",

  [string]$ReleaseRepo = "MikeyMan83/emergency-web-pi",

  [string]$Profile = "profiles/medical-survival-zimlist.txt",

  [string]$ContentDir = "artifacts/zim-cache",

  [string]$WorkspaceDir = "artifacts",

  [string]$ApSsid = "",

  [string]$ApPassword = "",

  [string]$CountryCode = "",

  # Pre-made device-config.json to copy onto the card instead of -ApSsid/-ApPassword.
  [string]$DeviceConfigPath = "",

  [ValidateSet("FirstBoot", "Prebuilt")]
  [string]$ContentMode = "Prebuilt",

  [switch]$AllowFixedDisk,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Require-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "create-sd-prebuilt.ps1 must be run from an elevated PowerShell session."
  }
}

function Resolve-WorkspacePath {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TargetDisk {
  param(
    [int]$Number,
    [switch]$AllowFixed
  )

  $disk = Get-Disk -Number $Number -ErrorAction Stop
  if ($disk.Size -le 0) {
    throw "Disk $Number reports zero capacity. Refusing to write."
  }
  if ($disk.BusType -eq "USB" -or $disk.BusType -eq "SD") {
    return $disk
  }
  if (-not $AllowFixed) {
    throw "Disk $Number is bus type '$($disk.BusType)'. Refusing to write. Re-run with -AllowFixedDisk only if you intentionally target a non-removable disk."
  }
  Write-Warning "Disk $Number is bus type '$($disk.BusType)' and -AllowFixedDisk was provided. Continuing by explicit override."
  return $disk
}

function Validate-PrebuiltManifest {
  param([Parameter(Mandatory = $true)]$Manifest)

  if ($Manifest.schemaVersion -ne 3) {
    throw "Unsupported base image manifest schemaVersion '$($Manifest.schemaVersion)'. This writer needs schemaVersion 3 (prebuilt-base)."
  }
  if ($Manifest.kind -ne "prebuilt-base") {
    throw "Manifest kind must be 'prebuilt-base'."
  }
  if ($Manifest.storage.zimdata.createdBy -ne "windows-writer") {
    throw "Manifest must declare storage.zimdata.createdBy = windows-writer."
  }
  if ($Manifest.contentPartition.filesystem -ne "exfat" -or $Manifest.contentPartition.label -ne "ZIMDATA") {
    throw "Manifest must declare an exfat content partition labelled ZIMDATA."
  }
  if ($Manifest.credentials -ne "device-config-on-first-boot") {
    throw "Manifest must declare credentials = device-config-on-first-boot."
  }
  if ([string]::IsNullOrWhiteSpace([string]$Manifest.image.sha256) -or [int64]$Manifest.image.sizeBytes -le 0) {
    throw "Manifest is missing image.sha256 or image.sizeBytes."
  }
}

function Get-GitHubToken {
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { return $env:GITHUB_TOKEN }
  if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return $env:GH_TOKEN }
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    try {
      $token = (& gh auth token 2>$null | Out-String).Trim()
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($token)) { return $token }
    } catch {
    }
  }
  return ""
}

function Save-ReleaseAsset {
  param(
    [Parameter(Mandatory = $true)]$Asset,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$Token,
    [string]$ProgressLabel = ""
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $uri = $Asset.url
  } else {
    $uri = $Asset.browser_download_url
  }
  $request = [System.Net.WebRequest]::Create($uri)
  $request.Method = "GET"
  $request.UserAgent = "EmergencyWebPi"
  $request.Accept = "application/octet-stream"
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $request.Headers["Authorization"] = "Bearer $Token"
  }
  # Bound the wait so a stalled connection fails instead of hanging silently:
  # 120 s to receive the response, 300 s maximum stall between reads.
  $request.Timeout = 120000
  $request.ReadWriteTimeout = 300000

  $response = $request.GetResponse()
  $total = $response.ContentLength
  $stream = $response.GetResponseStream()
  $file = [System.IO.File]::Create($Destination)
  try {
    $buffer = New-Object byte[] (1MB)
    [Int64]$downloaded = 0
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $file.Write($buffer, 0, $read)
      $downloaded += $read
      if ($watch.Elapsed.TotalSeconds -ge 1) {
        $watch.Reset()
        $watch.Start()
        Write-ReleaseAssetProgress -Label $ProgressLabel -Downloaded $downloaded -Total $total
      }
    }
  } finally {
    $file.Dispose()
    $stream.Dispose()
    $response.Dispose()
  }
  if ($ProgressLabel) {
    Write-ReleaseAssetProgress -Label $ProgressLabel -Downloaded $downloaded -Total $total
  }
}

function Write-ReleaseAssetProgress {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][Int64]$Downloaded,
    [Int64]$Total
  )

  $done = [math]::Round($Downloaded / 1MB, 1)
  if ($Total -gt 0) {
    $all = [math]::Round($Total / 1MB, 1)
    $percent = [int](($Downloaded * 100) / $Total)
    Write-Host ("${Label}: $done of $all MB ($percent%)")
  } else {
    Write-Host ("${Label}: $done MB downloaded")
  }
}

function Download-BaseImageAssets {
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$TargetDir
  )

  New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
  Write-Host "Looking up the base image release."
  $token = Get-GitHubToken
  $headers = @{ "User-Agent" = "EmergencyWebPi"; "Accept" = "application/vnd.github+json" }
  if (-not [string]::IsNullOrWhiteSpace($token)) {
    $headers["Authorization"] = "Bearer $token"
  }

  $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=20" -Headers $headers -TimeoutSec 120)
  foreach ($release in $releases) {
    if ($release.draft) { continue }
    $manifestAsset = @($release.assets | Where-Object { $_.name -like "ewp-base-*.img.manifest.json" })[0]
    if ($null -eq $manifestAsset) { continue }

    $manifestPath = Join-Path $TargetDir $manifestAsset.name
    Write-Host "Downloading base image manifest."
    Save-ReleaseAsset -Asset $manifestAsset -Destination $manifestPath -Token $token
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Validate-PrebuiltManifest -Manifest $manifest

    $names = @()
    if (@($manifest.distribution.parts).Count -gt 0) {
      $names = @($manifest.distribution.parts | ForEach-Object { $_.name })
    } else {
      $names = @($manifest.distribution.file)
    }

    $firstPath = ""
    foreach ($name in $names) {
      $asset = @($release.assets | Where-Object { $_.name -eq $name })[0]
      if ($null -eq $asset) {
        throw "Release $($release.tag_name) is missing asset $name."
      }
      $path = Join-Path $TargetDir $name
      if (-not (Test-Path $path) -or (Get-Item $path).Length -ne [int64]$asset.size) {
        Write-Host "Downloading base image asset: $name"
        Save-ReleaseAsset -Asset $asset -Destination $path -Token $token -ProgressLabel "Base image download"
      } else {
        Write-Host "Using cached base image asset: $name"
      }
      if ([string]::IsNullOrWhiteSpace($firstPath)) { $firstPath = $path }
    }
    return [PSCustomObject]@{ ImagePath = $firstPath; ManifestPath = $manifestPath }
  }

  throw "No release with an ewp-base image was found in $Repo."
}

function Expand-BaseImage {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $sourceDir = Split-Path -Parent $SourcePath

  if ($SourcePath.EndsWith(".img", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $SourcePath
  }

  $parts = @($Manifest.distribution.parts)
  $inputs = @()
  if ($parts.Count -gt 0) {
    foreach ($part in $parts) {
      $partPath = Join-Path $sourceDir $part.name
      if (-not (Test-Path $partPath)) {
        throw "Missing split image part: $($part.name)"
      }
      if ((Get-FileSha256 -Path $partPath) -ne ([string]$part.sha256).ToLowerInvariant()) {
        throw "SHA-256 mismatch for image part $($part.name)."
      }
      $inputs += $partPath
    }
  } else {
    $gzPath = Join-Path $sourceDir $Manifest.distribution.file
    if (-not (Test-Path $gzPath)) {
      throw "Missing image archive: $($Manifest.distribution.file)"
    }
    if ((Get-FileSha256 -Path $gzPath) -ne ([string]$Manifest.distribution.sha256).ToLowerInvariant()) {
      throw "SHA-256 mismatch for $($Manifest.distribution.file)."
    }
    $inputs += $gzPath
  }

  Write-Host "Unpacking base image ..."
  $tempGz = "$OutputPath.gz.tmp"
  $out = [System.IO.File]::Create($tempGz)
  try {
    $buffer = New-Object byte[] (4MB)
    $totalParts = 0
    foreach ($path in $inputs) { $totalParts += (Get-Item $path).Length }
    [Int64]$copied = 0
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($path in $inputs) {
      $in = [System.IO.File]::OpenRead($path)
      try {
        while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
          $out.Write($buffer, 0, $read)
          $copied += $read
          if ($watch.Elapsed.TotalSeconds -ge 2) {
            $watch.Reset()
            $watch.Start()
            Write-Host ("Unpacking base image: " + [math]::Round($copied / 1MB, 1) + " of " + [math]::Round($totalParts / 1MB, 1) + " MB")
          }
        }
      } finally { $in.Dispose() }
    }
  } finally {
    $out.Dispose()
  }

  $expectedSize = [int64]$Manifest.image.sizeBytes
  $gzIn = [System.IO.File]::OpenRead($tempGz)
  $gz = New-Object System.IO.Compression.GZipStream($gzIn, [System.IO.Compression.CompressionMode]::Decompress)
  $imgOut = [System.IO.File]::Create($OutputPath)
  try {
    $buffer = New-Object byte[] (4MB)
    [Int64]$unpacked = 0
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (($read = $gz.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $imgOut.Write($buffer, 0, $read)
      $unpacked += $read
      if ($watch.Elapsed.TotalSeconds -ge 2) {
        $watch.Reset()
        $watch.Start()
        if ($expectedSize -gt 0) {
          $percent = [int](($unpacked * 100) / $expectedSize)
          if ($percent -gt 100) { $percent = 100 }
          Write-Host ("Unpacking base image: " + [math]::Round($unpacked / 1MB, 1) + " of " + [math]::Round($expectedSize / 1MB, 1) + " MB ($percent%)")
        } else {
          Write-Host ("Unpacking base image: " + [math]::Round($unpacked / 1MB, 1) + " MB")
        }
      }
    }
  } finally {
    $imgOut.Dispose()
    $gz.Dispose()
    $gzIn.Dispose()
    Remove-Item $tempGz -Force -ErrorAction SilentlyContinue
  }
  return $OutputPath
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

  $imageSize = (Get-Item $ImagePath).Length
  if ($imageSize -gt $Disk.Size) {
    throw "Image size ($([math]::Round($imageSize / 1GB, 2)) GB) exceeds disk size ($([math]::Round($Disk.Size / 1GB, 2)) GB)."
  }

  Unmount-DiskVolumes -DiskNumber $DiskNumber
  Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null

  $targetPath = "\\.\PhysicalDrive$DiskNumber"
  $source = [System.IO.File]::Open($ImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  $target = New-Object System.IO.FileStream($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)

  try {
    $buffer = New-Object byte[] (4MB)
    [Int64]$totalBytes = $source.Length
    [Int64]$written = 0
    $lastPercent = -1
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
      # Raw device writes must be sector aligned.
      $writeLen = $read
      if (($writeLen % 512) -ne 0) {
        $writeLen = [int]([math]::Ceiling($read / 512.0) * 512)
        [Array]::Clear($buffer, $read, $writeLen - $read)
      }
      $target.Write($buffer, 0, $writeLen)
      $written += $read
      $percent = [int](($written * 100) / $totalBytes)
      # Report at most every 2 seconds and every 5 percent, so the UI shows
      # real progress without flooding the log.
      if ($percent -ne $lastPercent -and ($percent -ge $lastPercent + 5 -or $watch.Elapsed.TotalSeconds -ge 2)) {
        Write-Host "Writing appliance image: $percent%"
        $lastPercent = $percent
        $watch.Reset()
        $watch.Start()
      }
    }
    $target.Flush($true)
    Write-Host "Writing appliance image: 100%"
  } finally {
    $source.Dispose()
    $target.Dispose()
  }

  $verifyBytes = [Math]::Min($imageSize, 8MB)
  if ((Get-PartialHash -Path $ImagePath -BytesToHash $verifyBytes) -ne (Get-PartialHash -Path $targetPath -BytesToHash $verifyBytes)) {
    throw "Post-write verification failed: disk prefix hash does not match image prefix hash."
  }
}

function New-ZimDataVolume {
  param([Parameter(Mandatory = $true)][int]$DiskNumber)

  Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $disk = Get-Disk -Number $DiskNumber
  $partitionArgs = @{ DiskNumber = $DiskNumber; UseMaximumSize = $true; AssignDriveLetter = $true }
  if ($disk.PartitionStyle -eq "MBR") {
    $partitionArgs["MbrType"] = "IFS"
  }
  $partition = New-Partition @partitionArgs
  Start-Sleep -Seconds 2
  $volume = Format-Volume -Partition $partition -FileSystem exFAT -NewFileSystemLabel ZIMDATA -Confirm:$false
  Start-Sleep -Seconds 2

  $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
  if (-not $partition.DriveLetter) {
    throw "ZIMDATA volume was created but Windows did not assign a drive letter."
  }
  return ("{0}:\" -f $partition.DriveLetter)
}

function Resolve-AriaPath {
  $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($candidate in @("tools\aria2", "portable\tools\aria2", "tools")) {
    $path = Join-Path (Join-Path $repoRoot $candidate) "aria2c.exe"
    if (Test-Path $path) { return $path }
  }
  throw "aria2c.exe is required to download content. Use the complete release bundle, which includes it."
}

function Read-ProfileEntries {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "Profile file not found: $Path"
  }
  $urls = @()
  foreach ($line in Get-Content $Path) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
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

function Invoke-AriaDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Aria,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$OutputName
  )

  & $Aria -c --timeout=1800 --max-tries=3 --seed-time=0 -d $TargetDir -o $OutputName $Url
  if ($LASTEXITCODE -ne 0) {
    throw "Failed download: $Url"
  }
}

function New-DeviceConfigJson {
  param(
    [Parameter(Mandatory = $true)][string]$Ssid,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$Country
  )

  # Same rules the Pi enforces in scripts/device_config.py.
  if ($Ssid.Length -eq 0 -or [System.Text.Encoding]::UTF8.GetByteCount($Ssid) -gt 32 -or $Ssid -match '[\x00-\x1f\x7f]') {
    throw "Wi-Fi name must be 1-32 bytes with no control characters."
  }
  if ($Password -notmatch '^[\x20-\x7e]{8,63}$') {
    throw "Wi-Fi password must be 8-63 printable ASCII characters."
  }
  $ap = [ordered]@{ ssid = $Ssid; password = $Password }
  if (-not [string]::IsNullOrWhiteSpace($Country)) {
    if ($Country -cnotmatch '^[A-Z]{2}$') {
      throw "Country code must be two uppercase letters."
    }
    $ap["countryCode"] = $Country
  }
  return ([ordered]@{ schemaVersion = 1; ap = $ap } | ConvertTo-Json -Depth 5)
}

function Write-TextFile {
  param([string]$Path, [string]$Content)

  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "Checking administrator access."
Require-Admin
Write-Host "Checked: administrator access."

$resolvedWorkspace = Resolve-WorkspacePath -PathValue $WorkspaceDir
$resolvedCache = Resolve-WorkspacePath -PathValue $ContentDir
$baseCache = Join-Path $resolvedWorkspace "prebuilt-base-cache"
New-Item -ItemType Directory -Path $resolvedWorkspace -Force | Out-Null
New-Item -ItemType Directory -Path $resolvedCache -Force | Out-Null

if ($ConfirmDiskNumber -ne $DiskNumber) {
  throw "Set -ConfirmDiskNumber $DiskNumber to confirm destructive write target for disk #$DiskNumber."
}
if (-not $Force) {
  throw "Writing is destructive. Re-run with -Force to write to disk #$DiskNumber."
}

Write-Host "Checking target SD card (disk #$DiskNumber)."
$disk = Get-TargetDisk -Number $DiskNumber -AllowFixed:$AllowFixedDisk
Write-Host "Checked: SD card accepted - $($disk.FriendlyName), $([math]::Round($disk.Size / 1GB, 1)) GB, $($disk.BusType) bus."

Write-Host "Checking content profile."
$profilePath = Resolve-WorkspacePath -PathValue $Profile
$urls = Read-ProfileEntries -Path $profilePath
Write-Host "Checked: content profile has $($urls.Count) libraries."

Write-Host "Checking Wi-Fi configuration."
# Credentials first, so a bad value fails before anything is downloaded or erased.
if (-not [string]::IsNullOrWhiteSpace($DeviceConfigPath)) {
  if (-not (Test-Path $DeviceConfigPath)) { throw "Device config not found: $DeviceConfigPath" }
  $deviceConfig = Get-Content $DeviceConfigPath -Raw
  $parsed = $deviceConfig | ConvertFrom-Json
  $deviceConfig = New-DeviceConfigJson -Ssid ([string]$parsed.ap.ssid) -Password ([string]$parsed.ap.password) -Country ([string]$parsed.ap.countryCode)
} else {
  if ([string]::IsNullOrWhiteSpace($ApSsid) -or [string]::IsNullOrWhiteSpace($ApPassword)) {
    throw "Provide -ApSsid and -ApPassword, or -DeviceConfigPath."
  }
  $deviceConfig = New-DeviceConfigJson -Ssid $ApSsid -Password $ApPassword -Country $CountryCode
}
Write-Host "Checked: Wi-Fi configuration."

# Resolve and verify the base image.
if ([string]::IsNullOrWhiteSpace($ImagePath)) {
  try {
    $assets = Download-BaseImageAssets -Repo $ReleaseRepo -TargetDir $baseCache
  } catch {
    throw "BASE_IMAGE_UNAVAILABLE: could not download the base image from https://github.com/$ReleaseRepo/releases ($($_.Exception.Message)). Download the ewp-base files manually and pass -ImagePath."
  }
  $ImagePath = $assets.ImagePath
  if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = $assets.ManifestPath }
}
if (-not (Test-Path $ImagePath)) { throw "Image artifact not found: $ImagePath" }
$ImagePath = (Resolve-Path $ImagePath).Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $candidate = Get-ChildItem -Path (Split-Path -Parent $ImagePath) -Filter "ewp-base-*.img.manifest.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $candidate) { $candidate = Get-Item "$ImagePath.manifest.json" -ErrorAction SilentlyContinue }
  if ($null -eq $candidate) { throw "Base image manifest not found next to $ImagePath. Provide -ManifestPath." }
  $ManifestPath = $candidate.FullName
}
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
Validate-PrebuiltManifest -Manifest $manifest

$rawImagePath = Join-Path $resolvedWorkspace "prebuilt-base.img"
Write-Host "Verifying base image download (SHA-256)."
$rawImage = Expand-BaseImage -Manifest $manifest -SourcePath $ImagePath -OutputPath $rawImagePath
if ((Get-Item $rawImage).Length -ne [int64]$manifest.image.sizeBytes) {
  throw "Unpacked image size does not match the manifest."
}
Write-Host "Verifying unpacked base image (SHA-256)."
if ((Get-FileSha256 -Path $rawImage) -ne ([string]$manifest.image.sha256).ToLowerInvariant()) {
  throw "Unpacked image SHA-256 does not match the manifest."
}
Write-Host "Base image verified."

# Download content before erasing anything, so a failed download never leaves a wiped card.
$items = @()
$aria = ""
if ($ContentMode -eq "Prebuilt") {
  $aria = Resolve-AriaPath
  foreach ($url in $urls) {
    $name = Resolve-ZimFileName -Url $url
    $target = Join-Path $resolvedCache $name
    if (-not ((Test-Path $target -PathType Leaf) -and (Get-Item $target).Length -gt 0 -and -not (Test-Path "$target.aria2"))) {
      Write-Host "Downloading: $name"
      Invoke-AriaDownload -Aria $aria -Url $url -TargetDir $resolvedCache -OutputName $name
    } else {
      Write-Host "Using cached: $name"
    }
    $length = (Get-Item $target).Length
    if ($length -le 0) { throw "Downloaded file is empty: $name" }
    $items += [ordered]@{ name = $name; bytes = [int64]$length }
  }
  $needed = ($items | Measure-Object -Property bytes -Sum).Sum
  if ($needed + 1GB -gt $disk.Size) {
    throw "Selected content needs $([math]::Round($needed / 1GB, 1)) GB but the card holds $([math]::Round($disk.Size / 1GB, 1)) GB."
  }
}

Write-Host ""
Write-Host "Writing appliance image to disk #$DiskNumber ..."
Write-ImageToDisk -ImagePath $rawImage -DiskNumber $DiskNumber -Disk $disk

Write-Host "Creating ZIMDATA (exFAT) partition ..."
$zimRoot = New-ZimDataVolume -DiskNumber $DiskNumber

if ($ContentMode -eq "Prebuilt") {
  foreach ($item in $items) {
    Write-Host "Copying: $($item.name) ($([math]::Round($item.bytes / 1MB, 1)) MB)"
    $dest = Join-Path $zimRoot $item.name
    Copy-Item -Path (Join-Path $resolvedCache $item.name) -Destination $dest -Force
    if ((Get-Item $dest).Length -ne $item.bytes) {
      throw "Copied file size mismatch for $($item.name)."
    }
  }
  Write-TextFile -Path (Join-Path $zimRoot "content-manifest.json") -Content (([ordered]@{ schemaVersion = 1; items = $items } | ConvertTo-Json -Depth 5))
} else {
  Write-TextFile -Path (Join-Path $zimRoot ".content-install-pending") -Content "1"
}
Copy-Item -Path $profilePath -Destination (Join-Path $zimRoot "zimlist.txt") -Force
Write-TextFile -Path (Join-Path $zimRoot ".use_local_zimlist") -Content "1"
Write-TextFile -Path (Join-Path $zimRoot "device-config.json") -Content $deviceConfig
if ($ContentMode -eq "Prebuilt") {
  # Written last: its presence means every item above is complete.
  Write-TextFile -Path (Join-Path $zimRoot ".content-complete") -Content "1"
}

Write-Host "Flushing to the card ..."
Write-VolumeCache -DriveLetter $zimRoot.Substring(0, 1) -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Prebuilt SD build complete"
Write-Host "Disk:       #$DiskNumber"
Write-Host "ZIMDATA:    exFAT, $zimRoot"
if ($ContentMode -eq "Prebuilt") {
  Write-Host "Content:    $($items.Count) ZIM files copied; the Pi is ready offline on first boot"
} else {
  Write-Host "Content:    selected ZIM files will download on the Pi's first boot with Internet"
}
Write-Host "Next: safely eject the SD card and boot the Pi."
