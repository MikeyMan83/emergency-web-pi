param(
  [Parameter(Mandatory = $true)]
  [string]$BaseImagePath,

  [string]$ConfigPath = "config/appliance.example.json",

  [string]$OutputImagePath = "artifacts/appliance.img",

  [string]$ManifestPath = "",

  [string]$ZimSourceDir = "",

  [int]$MinZimPartitionGb = 8
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

$resolvedBaseImage = (Resolve-Path $BaseImagePath).Path
$resolvedConfig = (Resolve-Path $ConfigPath).Path
$resolvedOutput = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputImagePath))
$resolvedManifest = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  "$resolvedOutput.manifest.json"
} else {
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ManifestPath))
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
}

$cmd = @(
  "cd '$wslRepo'",
  "chmod +x scripts/build-appliance-image.sh",
  "sudo scripts/build-appliance-image.sh --base-image '$wslBase' --config '$wslConfig' --output '$wslOutput' --manifest '$wslManifest' --min-zim-partition-gb '$MinZimPartitionGb'$zimArg"
) -join " && "

Write-Host "Running Linux image builder in WSL..."
wsl bash -lc "$cmd"

Write-Host ""
Write-Host "Build complete"
Write-Host "Image:    $resolvedOutput"
Write-Host "Manifest: $resolvedManifest"
Write-Host "Next: run scripts/create-sd.ps1 -DiskNumber <N> -ImagePath '$resolvedOutput' -ManifestPath '$resolvedManifest' -Force"
