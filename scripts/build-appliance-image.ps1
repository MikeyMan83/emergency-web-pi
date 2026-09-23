param(
  [string]$BaseImagePath = "",

  [string]$BaseManifestPath = "config/base-image.json",

  [string]$BaseImageCacheDir = "artifacts/base-image-cache",

  [string]$ConfigPath = "config/appliance.example.json",

  [string]$ResolvedConfigPath = "artifacts/appliance-config.json",

  [string]$OutputImagePath = "artifacts/appliance.img",

  [string]$ManifestPath = "",

  [string]$ZimSourceDir = "",

  [int]$MinZimPartitionGb = 8,

  [switch]$AllowEmptyZimData
)

$ErrorActionPreference = "Stop"

function Require-Tool {
  param([Parameter(Mandatory = $true)][string]$Command)

  $null = Get-Command $Command -ErrorAction SilentlyContinue
  if (-not $?) {
    throw "Missing required command: $Command"
  }
}

function Require-WSL {
  $null = Get-Command wsl -ErrorAction SilentlyContinue
  if (-not $?) {
    throw "WSL is required. Install WSL and an Ubuntu distribution, then retry."
  }
}

function Require-WSLDistro {
  try {
    $distros = & wsl -l -q 2>$null
  } catch {
    throw "WSL is not installed. Run 'wsl --install -d Ubuntu', reboot, then retry."
  }

  if ($LASTEXITCODE -ne 0 -or -not $distros -or [string]::IsNullOrWhiteSpace(($distros | Out-String))) {
    throw "No WSL distribution is installed. Run 'wsl --install -d Ubuntu', reboot, then retry."
  }
}

Require-Tool -Command "wsl"
Require-WSL
Require-WSLDistro

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Resolve-RepoPath {
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
  $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
  $expectedHash = $manifest.sha256.ToString().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($manifest.downloadUrl) -or $expectedHash -notmatch "^[0-9a-f]{64}$") {
    throw "Pinned base-image manifest must define an official downloadUrl and SHA-256."
  }

  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  $fileName = [System.IO.Path]::GetFileName(([Uri]$manifest.downloadUrl).AbsolutePath)
  $imagePath = Join-Path $CacheDir $fileName
  if (Test-Path $imagePath -and (Get-FileSha256 -Path $imagePath) -eq $expectedHash) {
    Write-Host "Using verified Raspberry Pi OS image cache: $fileName"
    return $imagePath
  }

  Remove-Item -Force $imagePath -ErrorAction SilentlyContinue
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

$resolvedBaseManifest = Resolve-RepoPath -PathValue $BaseManifestPath
$resolvedBaseCache = Resolve-RepoPath -PathValue $BaseImageCacheDir
$resolvedBaseImage = Resolve-BaseImage -ProvidedImagePath $BaseImagePath -ManifestPath $resolvedBaseManifest -CacheDir $resolvedBaseCache
$sourceConfig = (Resolve-Path $ConfigPath).Path
$resolvedConfigOutput = Resolve-RepoPath -PathValue $ResolvedConfigPath
$configResolver = Join-Path $repoRoot "scripts/resolve-appliance-config.ps1"
$resolvedConfig = (& $configResolver -ConfigPath $sourceConfig -OutputPath $resolvedConfigOutput | Select-Object -Last 1).Trim()
$resolvedOutput = Resolve-RepoPath -PathValue $OutputImagePath
$resolvedManifest = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  "$resolvedOutput.manifest.json"
} else {
  Resolve-RepoPath -PathValue $ManifestPath
}

$wslRepo = wsl wslpath -a "$repoRoot"
$wslBase = wsl wslpath -a "$resolvedBaseImage"
$wslConfig = wsl wslpath -a "$resolvedConfig"
$wslOutput = wsl wslpath -a "$resolvedOutput"
$wslManifest = wsl wslpath -a "$resolvedManifest"

$zimArg = ""
if (-not [string]::IsNullOrWhiteSpace($ZimSourceDir)) {
  $resolvedZim = (Resolve-Path $ZimSourceDir).Path
  $wslZim = wsl wslpath -a "$resolvedZim"
  $zimArg = " --zim-source-dir '$wslZim'"
} elseif (-not $AllowEmptyZimData) {
  throw "ZimSourceDir is required for offline-ready appliance builds. Provide -ZimSourceDir, or use -AllowEmptyZimData for development-only images."
}

$emptyArg = ""
if ($AllowEmptyZimData) {
  $emptyArg = " --allow-empty-zimdata"
}

$cmd = @(
  "cd '$wslRepo'",
  "chmod +x scripts/build-appliance-image.sh",
  "sudo scripts/build-appliance-image.sh --base-image '$wslBase' --config '$wslConfig' --output '$wslOutput' --manifest '$wslManifest' --min-zim-partition-gb '$MinZimPartitionGb'$zimArg$emptyArg"
) -join " && "

Write-Host "Running Linux image builder in WSL..."
wsl bash -lc "$cmd"

Write-Host ""
Write-Host "Build complete"
Write-Host "Image:    $resolvedOutput"
Write-Host "Manifest: $resolvedManifest"
Write-Host "Config:   $resolvedConfig"
Write-Host "Next: run scripts/create-sd.ps1 -DiskNumber <N> -ConfirmDiskNumber <N> -ConfigPath '$resolvedConfig' -ImagePath '$resolvedOutput' -ManifestPath '$resolvedManifest' -Force"
