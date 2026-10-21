param(
  [Parameter(Mandatory = $true)]
  [string]$BundleDir,

  [int]$StartupTimeoutSeconds = 8
)

$ErrorActionPreference = "Stop"

$bundlePath = [System.IO.Path]::GetFullPath($BundleDir)
$frontendPath = Join-Path $bundlePath "portable/EmergencyWebPi.ps1"

if (-not (Test-Path $frontendPath)) {
  throw "Portable frontend is missing: $frontendPath"
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
      $content = Get-Content -Path $startupLog.FullName -Raw
      $reached = $true
      foreach ($checkpoint in $requiredCheckpoints) {
        if ($content -notmatch [regex]::Escape($checkpoint)) { $reached = $false; break }
      }
      if ($reached) { break }
    }
    Start-Sleep -Milliseconds 200
  }

  if ($null -eq $startupLog) {
    throw "Portable frontend did not create a startup log within $StartupTimeoutSeconds seconds."
  }

  $content = Get-Content -Path $startupLog.FullName -Raw
  foreach ($checkpoint in $requiredCheckpoints) {
    if ($content -notmatch [regex]::Escape($checkpoint)) {
      throw "Portable frontend did not reach startup checkpoint: $checkpoint"
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
