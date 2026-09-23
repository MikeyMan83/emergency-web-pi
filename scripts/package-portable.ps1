param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$OutputDir = "artifacts/release"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
$bundleName = "EmergencyWebPi-$Version-windows"
$bundleDir = Join-Path $releaseRoot $bundleName
$zipPath = Join-Path $releaseRoot "$bundleName.zip"
$checksumsPath = Join-Path $releaseRoot "$bundleName.sha256.txt"

if (Test-Path $bundleDir) {
  Remove-Item -Recurse -Force $bundleDir
}
if (Test-Path $zipPath) {
  Remove-Item -Force $zipPath
}
if (Test-Path $checksumsPath) {
  Remove-Item -Force $checksumsPath
}

New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

$copyItems = @(
  "Launch-EmergencyWebPi.cmd",
  "README.md",
  "HOWTO.md",
  "docs",
  "portable",
  "profiles",
  "scripts",
  "config",
  ".env.example",
  "zimlist.txt.example"
)

foreach ($item in $copyItems) {
  $src = Join-Path $repoRoot $item
  if (-not (Test-Path $src)) {
    throw "Missing required packaging path: $item"
  }
  Copy-Item -Path $src -Destination (Join-Path $bundleDir $item) -Recurse -Force
}

$startNote = @(
  "Emergency Web Pi $Version",
  "",
  "Quick start:",
  "1. Right-click EmergencyWebPi.exe and choose Run as administrator.",
  "2. Click Start End-User Wizard. Emergency Web Pi downloads and verifies the required Raspberry Pi OS image automatically.",
  "3. Select catalogs, target SD card, and content mode.",
  "4. Recommended first-boot mode downloads content on the Pi with temporary Internet; prebuilt mode is offline-ready immediately.",
  "5. Wait for completion, then insert SD card in Pi."
)
Set-Content -Path (Join-Path $bundleDir "START-HERE.txt") -Value $startNote -Encoding utf8

$portableScript = Join-Path $bundleDir "portable/EmergencyWebPi.ps1"
$portableExe = Join-Path $bundleDir "portable/EmergencyWebPi.exe"
$rootExe = Join-Path $bundleDir "EmergencyWebPi.exe"

try {
  $null = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction Stop
} catch {
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}

try {
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
} catch {
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
  Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force
Invoke-ps2exe -inputFile $portableScript -outputFile $portableExe -noConsole -title "Emergency Web Pi" -version $Version

if (-not (Test-Path $portableExe)) {
  throw "Failed to produce portable/EmergencyWebPi.exe. Release packaging requires a working EXE frontend."
}

Copy-Item -Path $portableExe -Destination $rootExe -Force

Compress-Archive -Path (Join-Path $bundleDir "*") -DestinationPath $zipPath -Force

$zipHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
$lines = @(
  "$zipHash  $(Split-Path -Leaf $zipPath)"
)
$exeHash = (Get-FileHash -Path $portableExe -Algorithm SHA256).Hash
$lines += "$exeHash  portable/EmergencyWebPi.exe"
$rootExeHash = (Get-FileHash -Path $rootExe -Algorithm SHA256).Hash
$lines += "$rootExeHash  EmergencyWebPi.exe"
Set-Content -Path $checksumsPath -Value $lines -Encoding ascii

Write-Host "Portable release package created"
Write-Host "Bundle dir: $bundleDir"
Write-Host "Zip:        $zipPath"
Write-Host "SHA256:     $checksumsPath"
