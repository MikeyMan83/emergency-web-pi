#Requires -Version 5.1
<#
.SYNOPSIS
    Headless lifecycle tests for the creator build startup transition
    (portable/EmergencyWebPi.ps1).
.DESCRIPTION
    Drives the REAL frontend functions - extracted with the PowerShell parser so
    the app's top-level startup, elevation and WPF-launch side effects never run -
    against fake writer scripts, using real child processes and real WPF
    dispatcher timers. Covers the v0.4.2 startup-stuck regression: manifest
    selection followed by a writer launch that never happened, a frozen elapsed
    timer, an empty details panel, and a Cancel button that could not recover.

    No SD card is involved: the fake writers only print. Windows-only; on other
    platforms the suite reports a skip and exits 0 so CI stays green.
#>

$ErrorActionPreference = "Stop"
$script:passed = 0
$script:failed = 0

function Assert-True {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
  if ($Condition) {
    $script:passed += 1
  } else {
    $script:failed += 1
    Write-Output ("FAIL: " + $Name)
  }
}

function Assert-Contains {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Haystack, [Parameter(Mandatory = $true)][string]$Needle, [Parameter(Mandatory = $true)][string]$Name)
  Assert-True ($Haystack.Contains($Needle)) ($Name + " (missing: " + $Needle + ")")
}

function Assert-NotContains {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Haystack, [Parameter(Mandatory = $true)][string]$Needle, [Parameter(Mandatory = $true)][string]$Name)
  Assert-True (-not $Haystack.Contains($Needle)) ($Name + " (unexpected: " + $Needle + ")")
}

# --- Platform / host guards -----------------------------------------------------
$isWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
if (-not $isWindowsHost) {
  Write-Output "SKIP: creator build-lifecycle tests need Windows (WPF + powershell.exe writers)."
  exit 0
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
  & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path @args
  exit $LASTEXITCODE
}
try {
  Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
  Add-Type -AssemblyName PresentationCore -ErrorAction Stop
  Add-Type -AssemblyName WindowsBase -ErrorAction Stop
} catch {
  Write-Output ("SKIP: WPF assemblies are unavailable: " + $_.Exception.Message)
  exit 0
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $repoRoot "portable/EmergencyWebPi-Core.ps1")

# --- Load the real frontend functions without running the app -------------------
$frontendPath = Join-Path $repoRoot "portable/EmergencyWebPi.ps1"
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($frontendPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
  throw ("frontend parse errors: " + ($parseErrors | ForEach-Object { $_.Message }))
}
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
  Invoke-Expression $fn.Extent.Text
}

# --- Test doubles ----------------------------------------------------------------
$tempDir = Join-Path $env:TEMP ("ewp-build-tests-" + (Get-Date).ToString("yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$workspace = Join-Path $tempDir "workspace"
$cache = Join-Path $tempDir "cache"
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
New-Item -ItemType Directory -Path $cache -Force | Out-Null

$script:repoRoot = $repoRoot
$script:logFile = Join-Path $tempDir "startup-test.log"
$script:appVersion = "test"
$script:workspaceDirectory = $workspace
$script:cacheDirectory = $cache
$script:uiDirectory = Join-Path $repoRoot "portable/ui"

$writersDir = Join-Path $tempDir "writers"
New-Item -ItemType Directory -Path $writersDir -Force | Out-Null
$writerParams = @'
param(
  [int]$DiskNumber, [int]$ConfirmDiskNumber, [string]$Profile, [string]$ContentDir,
  [string]$WorkspaceDir, [string]$ReleaseRepo, [string]$DeviceConfigPath,
  [string]$ContentMode, [switch]$Force, [string]$ImagePath, [string]$ManifestPath
)
function Write-WriterLine([string]$Text) {
  [Console]::Out.WriteLine($Text)
  [Console]::Out.Flush()
}
'@
function New-FakeWriter {
  param([string]$Name, [string]$Body)
  $path = Join-Path $writersDir $Name
  Set-Content -Path $path -Value ($writerParams + "`n" + $Body) -Encoding UTF8
  return $path
}

$writerOk = New-FakeWriter "writer-ok.ps1" @'
Write-WriterLine "Checking administrator access."
Write-WriterLine "Checked: administrator access."
Write-WriterLine "Verifying base image download (SHA-256)."
Write-WriterLine "Base image verified."
Write-WriterLine "Content download complete."
Write-WriterLine "Prebuilt SD build complete"
exit 0
'@
$writerBaseImageUnavailable = New-FakeWriter "writer-base-image-unavailable.ps1" @'
Write-WriterLine "Checking administrator access."
Write-WriterLine "Checked: administrator access."
Write-WriterLine "Checking target SD card (disk #$DiskNumber)."
throw "BASE_IMAGE_UNAVAILABLE: could not download the base image from https://github.com/$ReleaseRepo/releases (simulated)."
'@
$writerInvalidManifest = New-FakeWriter "writer-invalid-manifest.ps1" @'
Write-WriterLine "Checking administrator access."
Write-WriterLine "Checked: administrator access."
throw "Manifest kind must be 'prebuilt-base'."
'@
$writerSlowStart = New-FakeWriter "writer-slow-start.ps1" @'
Start-Sleep -Seconds 3
Write-WriterLine "Checking administrator access."
Write-WriterLine "Checked: administrator access."
Write-WriterLine "Prebuilt SD build complete"
exit 0
'@
$writerStreaming = New-FakeWriter "writer-streaming.ps1" @'
for ($i = 1; $i -le 12; $i++) {
  Write-WriterLine ("Checking administrator access. (line " + $i + ")")
  Start-Sleep -Milliseconds 300
}
exit 0
'@
$script:prebuiltScript = $writerOk
$script:dynamicScript = Join-Path $writersDir "writer-dynamic.ps1"
$script:buildImageScript = Join-Path $writersDir "writer-build-image.ps1"

# Fake base image + manifest for the retry picker.
$imageDir = Join-Path $tempDir "base-image"
New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
$imagePath = Join-Path $imageDir "ewp-base-1.0.0.img"
Set-Content -Path $imagePath -Value "fake image bytes"
$manifestPath = Join-Path $imageDir "ewp-base-1.0.0.img.manifest.json"
Set-Content -Path $manifestPath -Value '{"schemaVersion":3}'

# Fake window carrying the styles New-UiText looks up.
$window = New-Object System.Windows.Window
foreach ($styleKey in @("BodyText", "SectionLabel", "MetaText", "MutedText")) {
  $style = New-Object System.Windows.Style ([System.Windows.Controls.TextBlock])
  [void]$window.Resources.Add($styleKey, $style)
}
$script:window = $window

# Fake controls: real WPF elements so every property shape matches the app.
$script:ui = @{}
function Add-FakeControl {
  param([string]$Name, [System.Windows.UIElement]$Control)
  $script:ui[$Name] = $Control
}
foreach ($page in @("PageContent", "PageInstall", "PageSd", "PageReview", "PageProgress", "PageDone", "PageError", "FooterBar")) {
  Add-FakeControl $page (New-Object System.Windows.Controls.Border)
}
for ($i = 1; $i -le 4; $i++) {
  Add-FakeControl ("StepDot" + $i) (New-Object System.Windows.Controls.Border)
  Add-FakeControl ("StepDotText" + $i) (New-Object System.Windows.Controls.TextBlock)
  Add-FakeControl ("StepLine" + $i) (New-Object System.Windows.Controls.Border)
}
foreach ($btn in @("BtnBack", "BtnContinue", "BtnCancel", "BtnDeveloperTools")) {
  Add-FakeControl $btn (New-Object System.Windows.Controls.Button)
}
Add-FakeControl "StageListHost" (New-Object System.Windows.Controls.StackPanel)
Add-FakeControl "BuildBarTrack" (New-Object System.Windows.Controls.Canvas)
Add-FakeControl "BuildBarFill" (New-Object System.Windows.Controls.Border)
foreach ($txt in @("ProgressStatus", "ProgressTitle", "ProgressElapsed", "CancelNote", "ErrorMessage", "ErrorHint", "WifiSsidText", "WifiPasswordText", "WifiLabelNote")) {
  Add-FakeControl $txt (New-Object System.Windows.Controls.TextBlock)
}
$logTail = New-Object System.Windows.Controls.TextBox
Add-FakeControl "LogTail" $logTail
Add-FakeControl "ErrorLogTail" (New-Object System.Windows.Controls.TextBox)
Add-FakeControl "DetailsExpander" (New-Object System.Windows.Controls.Expander)
Add-FakeControl "ErrorDetailsExpander" (New-Object System.Windows.Controls.Expander)

$script:logTargets = New-Object System.Collections.Generic.List[object]
$script:logTargets.Add($logTail) | Out-Null

$script:app = [PSCustomObject]@{
  Catalog = $null
  BaseManifest = (Get-PinnedBaseImageInfo -RepoRoot $repoRoot)
  ProfilePaths = @()
  SelectedProfilePath = $null
  ContentMode = "Prebuilt"
  RequiredBytes = 0
  RequiredBytesKnown = $false
  DiskInventory = @()
  SelectedDiskNumber = 2
  SelectedDiskSnapshot = $null
  Step = 1
}
$libItem = [PSCustomObject]@{
  Id = "wikipedia_en_all_nopic.zim"
  Name = "Wikipedia - English"
  Description = "test library"
  EstimatedBytes = [int64]1000000
  SourceUrl = "https://example.com/wikipedia_en_all_nopic.zim"
  LearnMoreUrl = ""
  KnownSize = $true
}
$checkBox = New-Object System.Windows.Controls.CheckBox
$checkBox.IsChecked = $true
$script:libraryRows = @([PSCustomObject]@{ CheckBox = $checkBox; Item = $libItem })

function Reset-HarnessState {
  if ($script:elapsedTimer) { $script:elapsedTimer.Stop(); $script:elapsedTimer = $null }
  if ($script:marqueeTimer) { $script:marqueeTimer.Stop(); $script:marqueeTimer = $null }
  $script:buildJob = $null
  $script:buildCancelled = $false
  $script:buildStopRequested = $false
  $script:buildKillTarget = $null
  $script:buildCancelledAt = $null
  $script:buildExitedAt = $null
  $script:buildCompleted = $null
  $script:buildOnLine = $null
  $script:buildOnComplete = $null
  $script:buildOutputLines = $null
  $script:buildErrorLines = $null
  $script:activeStageId = $null
  $script:stageRows = @{}
  $script:stageOrder = @()
  $script:buildBarPercent = 0
  $script:buildStagePercent = 0
  $script:buildStartTime = $null
  $script:buildLastLineTime = $null
  $script:downloadItems = @()
  $script:downloadTotalWeight = 0
  $script:downloadCompletedWeight = 0
  $script:downloadCurrentItem = $null
  $script:downloadCurrentPercent = 0
  $script:copyTotalCount = 0
  $script:copyCompletedCount = 0
  $script:prebuiltFlow = $false
  $script:baseImageRetryDone = $false
  $script:filePickerOverride = $null
  $script:confirmOverride = $null
  $script:logTargets = New-Object System.Collections.Generic.List[object]
  $script:logTargets.Add($script:ui["LogTail"]) | Out-Null
  $script:ui["LogTail"].Text = ""
  $script:ui["ErrorLogTail"].Text = ""
  foreach ($page in @("PageContent", "PageInstall", "PageSd", "PageReview", "PageProgress", "PageDone", "PageError")) {
    $script:ui[$page].Visibility = "Collapsed"
  }
  $script:ui["PageProgress"].Visibility = "Visible"
  $script:ui["ProgressStatus"].Text = ""
  $script:ui["ProgressElapsed"].Text = ""
  $script:ui["ProgressTitle"].Text = ""
  $script:ui["ErrorMessage"].Text = ""
  $script:ui["ErrorHint"].Text = ""
  $script:ui["BtnCancel"].IsEnabled = $true
  $script:app.Step = 5
  $script:app.SelectedDiskNumber = 2
  $script:app.ContentMode = "Prebuilt"
  $script:app.RequiredBytes = 0
  $script:app.RequiredBytesKnown = $false
}

function Invoke-PumpUntil {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Condition,
    [int]$TimeoutSeconds = 30,
    [scriptblock]$OnTick = $null
  )
  $frame = New-Object System.Windows.Threading.DispatcherFrame
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(200)
  $timer.Add_Tick({
    if (& $Condition) { $frame.Continue = $false; return }
    if ((Get-Date) -gt $deadline) { $frame.Continue = $false; return }
    if ($OnTick) { & $OnTick }
  })
  $timer.Start()
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
  $timer.Stop()
  return (& $Condition)
}

function Test-FinishedPage {
  return (($script:ui["PageDone"].Visibility -eq "Visible") -or ($script:ui["PageError"].Visibility -eq "Visible"))
}

# --- Scenario 1: successful selection launches the writer and completes ---------
Reset-HarnessState
$script:prebuiltScript = $writerOk
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
$log1 = $logTail.Text

Assert-True $finished "S1: build reaches a finished page"
Assert-True ($script:ui["PageDone"].Visibility -eq "Visible") "S1: successful build shows the completion page"
Assert-True ($script:buildJob -and $script:buildJob.HasExited) "S1: writer process ran and exited"
Assert-True ($script:buildJob.ExitCode -eq 0) "S1: writer exit code is 0"
Assert-Contains $log1 "Checking administrator access." "S1: writer stdout reaches the details panel"
Assert-Contains $log1 "Prebuilt SD build complete" "S1: writer completion line reaches the panel"
Assert-Contains $log1 "Launching the writer process." "S1: launch phase is logged"
Assert-Contains $log1 "Waiting for the first writer response." "S1: first-response phase is logged"
Assert-Contains $log1 "Writer process started (pid" "S1: writer pid is recorded in diagnostics"
Assert-Contains $log1 "Writer working directory:" "S1: writer working directory is recorded"
Assert-NotContains $log1 "Build pump error" "S1: no pump errors"
Assert-True ($script:ui["ProgressStatus"].Text -eq "Finished.") "S1: final status is Finished."
Assert-True ($script:activeStageId -eq "done") "S1: final stage is done"
Assert-True ($script:ui["ProgressElapsed"].Text -match "^Elapsed: \d+ s$") "S1: elapsed time is displayed"

# --- Scenario 2: base image + manifest selection, then the retry writer launches -
Reset-HarnessState
$script:prebuiltScript = $writerBaseImageUnavailable
$script:pickerReturnTime = $null
$script:filePickerOverride = {
  param([string]$Filter, [string]$Title)
  if ($Title -match "base image$") {
    # The user picked the image; from now on the retry must launch this writer.
    $script:prebuiltScript = $writerOk
    $script:pickerReturnTime = Get-Date
    return $imagePath
  }
  return $null
}
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
$log2 = $logTail.Text

Assert-True $finished "S2: retry build reaches a finished page"
Assert-True ($script:ui["PageDone"].Visibility -eq "Visible") "S2: retry build completes"
Assert-Contains $log2 "Retrying with local base image" "S2: retry is logged"
Assert-Contains $log2 "Using local base image manifest" "S2: manifest auto-detection is logged"
Assert-Contains $log2 "Base image verified." "S2: the retry writer actually ran"
Assert-True ($log2 -match "Writer arguments:.*-ImagePath") "S2: retry writer receives -ImagePath"
Assert-True ($log2 -match "Writer arguments:.*-ManifestPath") "S2: retry writer receives -ManifestPath"
Assert-True ($script:pickerReturnTime -and $script:buildStartTime -ge $script:pickerReturnTime) "S2: elapsed tracking restarts for the retry"
Assert-NotContains $log2 "Build pump error" "S2: no pump errors"
Assert-NotContains $log2 "Cannot bind argument to parameter 'FilePath'" "S2: no writer-launch binding failure"

# --- Scenario 3: invalid/mismatched manifest surfaces the writer error -----------
Reset-HarnessState
$script:prebuiltScript = $writerInvalidManifest
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
$log3 = $logTail.Text

Assert-True $finished "S3: failed build reaches the error page"
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S3: manifest failure shows the error page"
Assert-True ($script:ui["ErrorMessage"].Text.Length -gt 0) "S3: error message is shown"
Assert-Contains $log3 "Manifest kind must be 'prebuilt-base'." "S3: writer validation error reaches the panel"
Assert-Contains $log3 "Build process finished (exit code 1)" "S3: writer exit status is recorded"
Assert-NotContains $log3 "Retrying with local base image" "S3: no base-image retry for a manifest error"

# --- Scenario 3b: UI-side validation failure returns to a usable state -----------
Reset-HarnessState
$script:libraryRows[0].Item.EstimatedBytes = [int64]0
$null = Start-CreatorBuild
$log3b = $logTail.Text
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S3b: validation failure shows the error page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The build could not be prepared.") "S3b: preparation failure message"
Assert-Contains $log3b "Build preparation failed" "S3b: preparation failure is logged"
Assert-True ($null -eq $script:buildJob) "S3b: no writer process was launched"
$script:libraryRows[0].Item.EstimatedBytes = [int64]1000000

# --- Scenario 4a: missing writer script reports a start failure ------------------
Reset-HarnessState
$script:prebuiltScript = (Join-Path $writersDir "does-not-exist.ps1")
$null = Start-CreatorBuild
$log4a = $logTail.Text
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S4a: missing writer shows the error page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The build helper could not be started.") "S4a: start-failure message"
Assert-Contains $log4a "Writer script not found" "S4a: missing writer script is logged"

# --- Scenario 4b: writer process creation failure reports the reason -------------
Reset-HarnessState
$script:prebuiltScript = $writerOk
$realSystemRoot = $env:SystemRoot
$env:SystemRoot = "C:\__ewp_nonexistent_systemroot__"
try {
  Start-CreatorBuild
} finally {
  $env:SystemRoot = $realSystemRoot
}
$log4b = $logTail.Text
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S4b: creation failure shows the error page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The build helper could not be started.") "S4b: creation failure message"
Assert-Contains $log4b "Could not start the writer process" "S4b: creation failure reason is logged"
Assert-True ($script:buildCompleted.Done) "S4b: failed launch completes the build state"

# --- Scenario 5: slow startup keeps the timer and the log live -------------------
Reset-HarnessState
$script:prebuiltScript = $writerSlowStart
$elapsedSamples = New-Object System.Collections.Generic.List[string]
$statusSamples = New-Object System.Collections.Generic.List[string]
$earlyLogHadLaunch = $false
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 40 -OnTick {
  $elapsedSamples.Add($script:ui["ProgressElapsed"].Text) | Out-Null
  $statusSamples.Add($script:ui["ProgressStatus"].Text) | Out-Null
  if (($logTail.Text.Contains("Launching the writer process.")) -and -not ($logTail.Text.Contains("Checking administrator access."))) {
    $script:earlyLogHadLaunch = $true
  }
}
$log5 = $logTail.Text

Assert-True $finished "S5: slow-start build completes"
Assert-True ($script:ui["PageDone"].Visibility -eq "Visible") "S5: slow-start build succeeds"
Assert-True (@($statusSamples | Where-Object { $_ -eq "Waiting for the first writer response..." }).Count -gt 0) "S5: first-response status shown during silent startup"
$distinctElapsed = @($elapsedSamples | Where-Object { $_ -match "^Elapsed: \d+ s$" } | Select-Object -Unique)
Assert-True ($distinctElapsed.Count -ge 2) ("S5: elapsed timer advances during a silent writer (got: " + ($distinctElapsed -join ", ") + ")")
Assert-True $script:earlyLogHadLaunch "S5: startup diagnostics appear before the first writer line"
Assert-Contains $log5 "Checking administrator access." "S5: writer output arrives after the slow start"

# --- Scenario 6a: cancel before process creation returns to a usable state -------
Reset-HarnessState
Stop-BuildProcess
$log6a = $logTail.Text
Assert-True ($script:buildCancelled) "S6a: cancel is recorded"
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S6a: cancel before launch leaves the progress page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The operation was cancelled.") "S6a: cancelled state message"
Assert-Contains $log6a "No build process was running." "S6a: missing writer is logged"

# --- Scenario 6b: cancel in the stuck retry state returns to a usable state -------
Reset-HarnessState
$script:prebuiltScript = $writerOk
$null = Start-CreatorBuild
[void](Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30)
# Simulate the reported v0.4.2 stuck state: the first writer already exited, its
# completion already ran, and the user is on the progress page with Cancel enabled.
$script:app.Step = 5
$script:ui["PageProgress"].Visibility = "Visible"
$script:ui["PageDone"].Visibility = "Collapsed"
$script:ui["BtnCancel"].IsEnabled = $true
$script:buildStopRequested = $false
$script:buildCancelled = $false
Stop-BuildProcess
$log6b = $logTail.Text
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S6b: cancel in the stuck state leaves the progress page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The operation was cancelled.") "S6b: cancelled state message"
Assert-True ($script:ui["BtnCancel"].IsEnabled -eq $false) "S6b: cancel button is disabled after cancelling"

# --- Scenario 6c: cancel while output streams are drained, then a fresh attempt ---
Reset-HarnessState
$script:prebuiltScript = $writerStreaming
$cancelTimer = New-Object System.Windows.Threading.DispatcherTimer
$cancelTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$cancelTimer.Add_Tick({
  param($sender, $eventArgs)
  $sender.Stop()
  Stop-BuildProcess
})
$null = Start-CreatorBuild
$cancelTimer.Start()
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
$cancelTimer.Stop()
$log6c = $logTail.Text

Assert-True $finished "S6c: cancelled build reaches a finished page"
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S6c: cancel while draining shows the cancelled state"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The operation was cancelled.") "S6c: cancelled state message"
Assert-Contains $log6c "Cancellation requested" "S6c: cancellation is logged"
Assert-True ($script:buildJob.HasExited) "S6c: writer process was stopped"
# Ready for another attempt.
$script:prebuiltScript = $writerOk
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
Assert-True $finished "S6c: a new build can start after cancellation"
Assert-True ($script:ui["PageDone"].Visibility -eq "Visible") "S6c: the new build completes"
Assert-True ($script:buildJob.ExitCode -eq 0) "S6c: the new build succeeds"

# --- Scenario 6d: cancel while the base-image picker is open prevents the retry ---
Reset-HarnessState
$script:prebuiltScript = $writerBaseImageUnavailable
$script:filePickerOverride = {
  param([string]$Filter, [string]$Title)
  if ($Title -match "base image$") {
    # The user hits Cancel while the picker is open, then confirms a file anyway.
    Stop-BuildProcess
    $script:prebuiltScript = $writerOk
    return $imagePath
  }
  return $null
}
$null = Start-CreatorBuild
$finished = Invoke-PumpUntil -Condition { Test-FinishedPage } -TimeoutSeconds 30
$log6d = $logTail.Text

Assert-True $finished "S6d: picker-window cancel reaches a finished page"
Assert-True ($script:ui["PageError"].Visibility -eq "Visible") "S6d: picker-window cancel leaves the progress page"
Assert-True ($script:ui["ErrorMessage"].Text -eq "The operation was cancelled.") "S6d: cancelled state message"
Assert-Contains $log6d "Retry cancelled before the writer was launched." "S6d: retry is not launched after cancel"
Assert-NotContains $log6d "Base image verified." "S6d: the retry writer never ran"

# --- Cleanup ----------------------------------------------------------------------
if ($script:buildJob -and -not $script:buildJob.HasExited) {
  try { $script:buildJob.Kill() } catch { }
}
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Summary ----------------------------------------------------------------------
Write-Output ("")
Write-Output ("Creator build-lifecycle tests: " + $script:passed + " passed, " + $script:failed + " failed.")
if ($script:failed -gt 0) {
  exit 1
}
exit 0
