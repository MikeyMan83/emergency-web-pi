param(
  [Parameter(Mandatory = $true)]
  [string]$BootPath,

  [Parameter(Mandatory = $true)]
  [string]$RepoUrl,

  [string]$RepoBranch = "main",
  [string]$BootstrapRawUrl = "",
  [string]$ZimListRawUrl = "",
  [string]$BootstrapUser = "",
  [int]$SyncIntervalSeconds = 86400,
  [int]$KiwixPort = 8080,
  [string]$GitHubToken = "",
  [switch]$EnableSsh
)

$ErrorActionPreference = "Stop"

function Escape-BashSingleQuotedValue {
  param([string]$Value)
  return $Value -replace "'", "'\"'\"'"
}

$bootRoot = (Resolve-Path $BootPath).Path

if (-not (Test-Path (Join-Path $bootRoot "config.txt")) -and -not (Test-Path (Join-Path $bootRoot "cmdline.txt"))) {
  throw "Boot path does not look like a Raspberry Pi boot partition: $bootRoot"
}

if ([string]::IsNullOrWhiteSpace($BootstrapRawUrl)) {
  if ($RepoUrl -match '^https://github.com/([^/]+)/([^/.]+)(\.git)?$') {
    $owner = $Matches[1]
    $repo = $Matches[2]
    $BootstrapRawUrl = "https://raw.githubusercontent.com/$owner/$repo/$RepoBranch/scripts/bootstrap-pi.sh"
  } else {
    throw "Could not infer BootstrapRawUrl from RepoUrl. Pass -BootstrapRawUrl explicitly."
  }
}

$scriptLines = @(
  "#!/bin/bash",
  "set -euo pipefail",
  "",
  "LOG_FILE=/boot/firmware/pi-kiwix-firstboot.log",
  "if [ ! -d /boot/firmware ]; then LOG_FILE=/boot/pi-kiwix-firstboot.log; fi",
  "exec > >(tee -a \"$LOG_FILE\") 2>&1",
  "",
  "export REPO_URL='$(Escape-BashSingleQuotedValue $RepoUrl)'",
  "export REPO_BRANCH='$(Escape-BashSingleQuotedValue $RepoBranch)'"
)

if (-not [string]::IsNullOrWhiteSpace($BootstrapUser)) {
  $scriptLines += "export BOOTSTRAP_USER='$(Escape-BashSingleQuotedValue $BootstrapUser)'"
}

if (-not [string]::IsNullOrWhiteSpace($ZimListRawUrl)) {
  $scriptLines += "export BOOTSTRAP_GITHUB_URL='$(Escape-BashSingleQuotedValue $ZimListRawUrl)'"
}

$scriptLines += "export BOOTSTRAP_SYNC_INTERVAL_SECONDS='$SyncIntervalSeconds'"
$scriptLines += "export BOOTSTRAP_KIWIX_PORT='$KiwixPort'"

if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
  $scriptLines += "export BOOTSTRAP_GITHUB_TOKEN='$(Escape-BashSingleQuotedValue $GitHubToken)'"
}

$scriptLines += @(
  "",
  "curl -fsSL '$(Escape-BashSingleQuotedValue $BootstrapRawUrl)' | bash"
)

$firstrunContent = ($scriptLines -join "`n") + "`n"
$firstrunPath = Join-Path $bootRoot "firstrun.sh"
[System.IO.File]::WriteAllText($firstrunPath, $firstrunContent, (New-Object System.Text.UTF8Encoding($false)))

if ($EnableSsh) {
  $sshFlagPath = Join-Path $bootRoot "ssh"
  if (-not (Test-Path $sshFlagPath)) {
    New-Item -Path $sshFlagPath -ItemType File | Out-Null
  }
}

Write-Host "Wrote $firstrunPath"
if ($EnableSsh) {
  Write-Host "Enabled SSH via boot partition flag file"
}
Write-Host "Unattended first boot is prepared."
