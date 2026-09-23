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

Remove-Item -Path (Join-Path $bundleDir "portable/Launch-EmergencyWebPi.cmd") -Force

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
$portableLauncherScript = Join-Path $bundleDir "portable/EmergencyWebPi-launcher.ps1"
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

$escapedOutput = $rootExe.Replace("'", "''")
$escapedVersion = $Version.Replace("'", "''")
$launcherSource = @'
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$executablePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$baseDirectory = Split-Path -Parent $executablePath
$scriptPath = Join-Path $baseDirectory "EmergencyWebPi.ps1"

if (-not (Test-Path $scriptPath)) {
  $scriptPath = Join-Path $baseDirectory "portable\EmergencyWebPi.ps1"
}

$logDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EmergencyWebPi"
$logPath = Join-Path $logDirectory "launcher.log"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Add-Content -Path $logPath -Value ("[{0}] EXE launcher started. Frontend: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $scriptPath) -Encoding utf8

if (-not (Test-Path $scriptPath)) {
  [System.Windows.Forms.MessageBox]::Show("Emergency Web Pi frontend is missing. Extract the complete release ZIP and retry.`n`nDiagnostic log:`n$logPath", "Emergency Web Pi", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  exit 1
}

Add-Content -Path $logPath -Value ("[{0}] Starting frontend PowerShell process." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")) -Encoding utf8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
$exitCode = $LASTEXITCODE
Add-Content -Path $logPath -Value ("[{0}] Frontend PowerShell process exited with code {1}." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $exitCode) -Encoding utf8
exit $exitCode
'@
Set-Content -Path $portableLauncherScript -Value $launcherSource -Encoding utf8

$escapedInput = $portableLauncherScript.Replace("'", "''")
$compileCommand = "Import-Module ps2exe -Force; Invoke-ps2exe -inputFile '$escapedInput' -outputFile '$escapedOutput' -noConsole -title 'Emergency Web Pi' -version '$escapedVersion'"
$powershellHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
& $powershellHost -NoProfile -Command $compileCommand
if ($LASTEXITCODE -ne 0) {
  throw "ps2exe failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path $rootExe)) {
  throw "Failed to produce EmergencyWebPi.exe. Release packaging requires a working EXE frontend."
}

Compress-Archive -Path (Join-Path $bundleDir "*") -DestinationPath $zipPath -Force

$zipHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
$lines = @(
  "$zipHash  $(Split-Path -Leaf $zipPath)"
)
$rootExeHash = (Get-FileHash -Path $rootExe -Algorithm SHA256).Hash
$lines += "$rootExeHash  EmergencyWebPi.exe"
Set-Content -Path $checksumsPath -Value $lines -Encoding ascii

Write-Host "Portable release package created"
Write-Host "Bundle dir: $bundleDir"
Write-Host "Zip:        $zipPath"
Write-Host "SHA256:     $checksumsPath"
