param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  $repoRoot = Split-Path -Parent $PSScriptRoot
  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
}

function New-ApPassword {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%*+-_'
  $bytes = New-Object byte[] 20
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $password = New-Object System.Text.StringBuilder
  foreach ($byte in $bytes) {
    [void]$password.Append($chars[$byte % $chars.Length])
  }
  return $password.ToString()
}

$resolvedConfigPath = Resolve-RepoPath -PathValue $ConfigPath
$resolvedOutputPath = Resolve-RepoPath -PathValue $OutputPath

if (-not (Test-Path $resolvedConfigPath)) {
  throw "Config file not found: $resolvedConfigPath"
}

try {
  $config = Get-Content $resolvedConfigPath -Raw | ConvertFrom-Json
} catch {
  throw "Config file is not valid JSON: $resolvedConfigPath"
}

if ($null -eq $config.network -or $null -eq $config.network.ap -or [string]::IsNullOrWhiteSpace($config.network.ap.password)) {
  throw "Config must set network.ap.password."
}

$placeholderPasswords = @("__GENERATE__", "ChangeThisEmergencyPassword123")
if ($placeholderPasswords -contains $config.network.ap.password) {
  $config.network.ap.password = New-ApPassword
  Write-Host "Generated a private emergency AP password for this build."
}

if ($config.network.ap.password.Length -lt 8 -or $config.network.ap.password.Length -gt 63) {
  throw "network.ap.password must be 8-63 characters for WPA2."
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path $outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

($config | ConvertTo-Json -Depth 10) + "`n" | Set-Content -Path $resolvedOutputPath -Encoding utf8
Write-Output $resolvedOutputPath