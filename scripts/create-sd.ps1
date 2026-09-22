param(
  [Parameter(Mandatory = $true)]
  [int]$DiskNumber,

  [string]$ConfigPath = "config/appliance.example.json",

  [string]$ImagePath = "",

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

function Get-TargetDisk {
  param([int]$Number)

  $disk = Get-Disk -Number $Number -ErrorAction Stop
  if ($disk.BusType -eq "USB" -or $disk.BusType -eq "SD") {
    return $disk
  }

  Write-Warning "Disk $Number is bus type '$($disk.BusType)'. Double-check you selected the removable SD target."
  return $disk
}

Require-Admin

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$config = Read-Config -Path $ConfigPath
Validate-Config -Config $config

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

if ([string]::IsNullOrWhiteSpace($ImagePath)) {
  throw @"
No appliance image artifact was provided.

`scripts/create-sd.ps1` expects a finished appliance image artifact.
Provide -ImagePath with that artifact, then re-run the command.
"@
}

if (-not (Test-Path $ImagePath)) {
  throw "Image artifact not found: $ImagePath"
}

if (-not $Force) {
  Write-Warning "Image writing is destructive. Re-run with -Force to allow writing once an appliance image artifact is provided."
  return
}

throw "Image writing is not available from this script revision. See docs/APPLIANCE.md for the appliance contract."