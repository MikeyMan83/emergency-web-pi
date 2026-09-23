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

$logDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EmergencyWebPi"
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
    $startupLog = Get-ChildItem -Path $logDirectory -Filter "startup-*.log" -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $startedAfter } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($null -ne $startupLog) {
      $content = Get-Content -Path $startupLog.FullName -Raw
      if ($content -match "WinForms assemblies loaded\." -and
          $content -match "Required builder scripts found\." -and
          $content -match "Opening end-user wizard\.") {
        break
      }
    }
    Start-Sleep -Milliseconds 200
  }

  if ($null -eq $startupLog) {
    throw "Portable frontend did not create a startup log within $StartupTimeoutSeconds seconds."
  }

  $content = Get-Content -Path $startupLog.FullName -Raw
  foreach ($checkpoint in @("WinForms assemblies loaded.", "Required builder scripts found.", "Opening end-user wizard.")) {
    if ($content -notmatch [regex]::Escape($checkpoint)) {
      throw "Portable frontend did not reach startup checkpoint: $checkpoint"
    }
  }

  if ($process.HasExited) {
    throw "Portable frontend exited during startup with code $($process.ExitCode)."
  }

  Write-Output "Portable frontend smoke test passed: wizard process is alive and startup checkpoints were logged."
} finally {
  if (-not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
}
