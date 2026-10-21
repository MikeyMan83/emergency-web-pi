param(
  [Parameter(Mandatory = $true)]
  [string]$BundleDir,

  # Cold CI runners need more than a few seconds to load WPF and read the
  # freshly written bundle files; keep this timeout generous.
  [int]$StartupTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

$bundlePath = [System.IO.Path]::GetFullPath($BundleDir)
$frontendPath = Join-Path $bundlePath "portable/EmergencyWebPi.ps1"

if (-not (Test-Path $frontendPath)) {
  throw "Portable frontend is missing: $frontendPath"
}

function Read-LogFileContent {
  param([Parameter(Mandatory)][string]$Path)
  # Get-Content opens files with a read-only share, which makes the frontend's
  # Add-Content appends fail while we poll ("The stream is not readable").
  # Read through a handle that shares write access so polling never blocks the
  # frontend's logging.
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
      try {
        $reader = New-Object System.IO.StreamReader($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
      } finally { $stream.Dispose() }
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 100
    }
  }
  return $null
}

$logDirectories = @(
  (Join-Path $bundlePath "logs"),
  (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EmergencyWebPi")
)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$requiredCheckpoints = @("WPF assemblies loaded.", "Required builder scripts found.", "Opening the Emergency Web Pi creator.")
if (-not $isAdmin) {
  # Without administrator rights the correct startup behavior is the elevation
  # handoff: the frontend boots, then asks Windows for permission. The creator
  # window itself can only be validated from an administrator session.
  $requiredCheckpoints = @("WPF assemblies loaded.", "requesting elevation via UAC")
}

$startedAfter = Get-Date
$process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
  "-STA",
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $frontendPath
) -WorkingDirectory $bundlePath -PassThru

try {
  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  $startupLog = $null
  while ((Get-Date) -lt $deadline) {
    $startupLog = Get-ChildItem -Path $logDirectories -Filter "startup-*.log" -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $startedAfter } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($null -ne $startupLog) {
      $content = Read-LogFileContent -Path $startupLog.FullName
      $reached = $true
      foreach ($checkpoint in $requiredCheckpoints) {
        if ($content -notmatch [regex]::Escape($checkpoint)) { $reached = $false; break }
      }
      if ($reached) { break }
    }
    Start-Sleep -Milliseconds 200
  }

  if ($null -eq $startupLog) {
    throw ("Portable frontend did not create a startup log within {0} seconds. Searched: {1}" -f $StartupTimeoutSeconds, ($logDirectories -join '; '))
  }

  $content = Read-LogFileContent -Path $startupLog.FullName
  foreach ($checkpoint in $requiredCheckpoints) {
    if ($content -notmatch [regex]::Escape($checkpoint)) {
      $tail = @($content -split "`r?`n" | Select-Object -Last 30)
      throw ("Portable frontend did not reach startup checkpoint: {0}. Startup log {1}:`n{2}" -f $checkpoint, $startupLog.FullName, ($tail -join "`n"))
    }
  }

  if (-not $isAdmin) {
    Write-Output "Portable frontend smoke test passed (limited): the bundle boots and requests administrator permission. The creator window itself requires an administrator session."
    return
  }

  if ($process.HasExited) {
    throw "Portable frontend exited during startup with code $($process.ExitCode)."
  }

  Write-Output "Portable frontend smoke test passed: creator process is alive and startup checkpoints were logged."
} finally {
  if (-not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
}
