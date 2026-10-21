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

# Bundle the pinned, SHA-256-verified aria2 download utility so end users
# never need to install aria2 manually for prebuilt content downloads.
$aria2ManifestPath = Join-Path $repoRoot "config\aria2.json"
if (-not (Test-Path $aria2ManifestPath)) {
  throw "Missing required packaging path: config/aria2.json"
}
$aria2Manifest = Get-Content $aria2ManifestPath -Raw | ConvertFrom-Json
foreach ($field in @("downloadUrl", "sha256")) {
  if ([string]::IsNullOrWhiteSpace($aria2Manifest.$field)) {
    throw "Pinned aria2 manifest must set $field."
  }
}
$aria2ExpectedHash = $aria2Manifest.sha256.ToLowerInvariant()
$aria2CacheDir = Join-Path $repoRoot "artifacts\aria2-cache"
New-Item -ItemType Directory -Path $aria2CacheDir -Force | Out-Null
$aria2ZipName = [System.IO.Path]::GetFileName(([Uri]$aria2Manifest.downloadUrl).AbsolutePath)
$aria2ZipPath = Join-Path $aria2CacheDir $aria2ZipName
if (Test-Path $aria2ZipPath) {
  if ((Get-FileHash -Path $aria2ZipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $aria2ExpectedHash) {
    Remove-Item -Force $aria2ZipPath
  }
}
if (-not (Test-Path $aria2ZipPath)) {
  Write-Host "Downloading pinned aria2 $($aria2Manifest.version)..."
  $aria2TempPath = "$aria2ZipPath.download"
  Remove-Item -Force $aria2TempPath -ErrorAction SilentlyContinue
  Invoke-WebRequest -Uri $aria2Manifest.downloadUrl -OutFile $aria2TempPath -UseBasicParsing
  if ((Get-FileHash -Path $aria2TempPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $aria2ExpectedHash) {
    Remove-Item -Force $aria2TempPath -ErrorAction SilentlyContinue
    throw "Downloaded aria2 archive failed SHA-256 verification."
  }
  Move-Item -Path $aria2TempPath -Destination $aria2ZipPath -Force
}
$aria2ExtractDir = Join-Path $aria2CacheDir "extract"
if (Test-Path $aria2ExtractDir) {
  Remove-Item -Recurse -Force $aria2ExtractDir
}
Expand-Archive -Path $aria2ZipPath -DestinationPath $aria2ExtractDir -Force
$aria2Exe = Get-ChildItem -Path $aria2ExtractDir -Recurse -Filter "aria2c.exe" | Select-Object -First 1
if ($null -eq $aria2Exe) {
  throw "aria2c.exe not found in the pinned aria2 archive."
}
$bundleToolsDir = Join-Path $bundleDir "tools\aria2"
New-Item -ItemType Directory -Path $bundleToolsDir -Force | Out-Null
Copy-Item -Path $aria2Exe.FullName -Destination (Join-Path $bundleToolsDir "aria2c.exe") -Force
Write-Host "Bundled aria2c.exe (pinned $($aria2Manifest.version))."

Remove-Item -Path (Join-Path $bundleDir "portable/Launch-EmergencyWebPi.cmd") -Force

$startNote = @(
  "Emergency Web Pi $Version",
  "",
  "Quick start:",
  "1. Double-click EmergencyWebPi.exe and click Yes when Windows asks for permission. The app needs this to write the SD card.",
  "   If Windows first shows a blue box saying 'Windows protected your PC', click 'More info' and then 'Run anyway'. The app is not code-signed yet, so this warning is expected; the .sha256.txt file next to the download lets you verify it.",
  "2. The creator opens automatically. Emergency Web Pi downloads and verifies the required Raspberry Pi OS image automatically.",
  "3. Choose a content profile, the SD card to erase, and an installation method.",
  "4. Recommended: Prepare everything now. This downloads content now, so the card works offline immediately; the first-boot option downloads on the Pi with temporary Internet.",
  "5. Wait for completion. The app shows the emergency Wi-Fi name and password and saves a printable label on your Desktop.",
  "6. Safely eject the SD card, insert it in the Pi, and power it on.",
  ""
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

$logDirectory = Join-Path $baseDirectory "logs"
try {
  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
  $probePath = Join-Path $logDirectory (".probe-{0}" -f [guid]::NewGuid().ToString("N"))
  Set-Content -Path $probePath -Value "ok"
  Remove-Item -Path $probePath -Force
} catch {
  $logDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EmergencyWebPi"
}
$logPath = Join-Path $logDirectory "launcher.log"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Add-Content -Path $logPath -Value ("[{0}] EXE launcher started. Frontend: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $scriptPath) -Encoding utf8

if (-not (Test-Path $scriptPath)) {
  [System.Windows.Forms.MessageBox]::Show("Emergency Web Pi frontend is missing. Extract the complete release ZIP and retry.`n`nDiagnostic log:`n$logPath", "Emergency Web Pi", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  exit 1
}

Add-Content -Path $logPath -Value ("[{0}] Starting frontend PowerShell process." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")) -Encoding utf8
& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $scriptPath
$exitCode = $LASTEXITCODE
Add-Content -Path $logPath -Value ("[{0}] Frontend PowerShell process exited with code {1}." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $exitCode) -Encoding utf8
exit $exitCode
'@
Set-Content -Path $portableLauncherScript -Value $launcherSource -Encoding utf8

$escapedInput = $portableLauncherScript.Replace("'", "''")
$compileCommand = "Import-Module ps2exe -Force; Invoke-ps2exe -inputFile '$escapedInput' -outputFile '$escapedOutput' -noConsole -requireAdmin -title 'Emergency Web Pi' -version '$escapedVersion'"
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
