$ErrorActionPreference = "Stop"
$appDisplayName = "Emergency Web Pi"
$logDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EmergencyWebPi"
$workspaceDirectory = Join-Path $logDirectory "workspace"
$logPath = Join-Path $logDirectory ("startup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-AppLog {
  param([Parameter(Mandatory = $true)][string]$Message)

  try {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message) -Encoding utf8
  } catch {
  }
}

Write-AppLog "Frontend startup requested."

$script:startupStage = "Loading WinForms assemblies"
try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()
  Write-AppLog "WinForms assemblies loaded."
} catch {
  Write-AppLog ("Failed during $script:startupStage: {0}" -f $_.Exception.ToString())
  exit 1
}

trap {
  Write-AppLog ("Unhandled error: {0}" -f $_.Exception.ToString())
  [System.Windows.Forms.MessageBox]::Show(
    "$($_.Exception.Message)`n`nDiagnostic log:`n$logPath",
    $appDisplayName,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

$candidateDirs = @()
if ($PSScriptRoot) {
  $candidateDirs += $PSScriptRoot
}
if ($MyInvocation.MyCommand.Path) {
  $candidateDirs += (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if ($PSCommandPath) {
  $candidateDirs += (Split-Path -Parent $PSCommandPath)
}
if ([System.AppDomain]::CurrentDomain.BaseDirectory) {
  $candidateDirs += ([System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\\'))
}
try {
  $procPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  if ($procPath) {
    $candidateDirs += (Split-Path -Parent $procPath)
  }
} catch {
}
$candidateDirs += (Get-Location).Path
Write-AppLog "Resolving extracted bundle location."

$repoRoot = ""
foreach ($dir in ($candidateDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
  $direct = Join-Path $dir "scripts/create-sd-dynamic.ps1"
  if (Test-Path $direct) {
    $repoRoot = [System.IO.Path]::GetFullPath($dir)
    break
  }

  $parent = [System.IO.Path]::GetFullPath((Join-Path $dir ".."))
  $parentDirect = Join-Path $parent "scripts/create-sd-dynamic.ps1"
  if (Test-Path $parentDirect) {
    $repoRoot = $parent
    break
  }
}

if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  Write-AppLog "Bundled script discovery failed. Checked: $($candidateDirs -join '; ')"
  $checked = ($candidateDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join "`n"
  [System.Windows.Forms.MessageBox]::Show(
    "Unable to locate bundled scripts.`n`nExtract the full release ZIP first, then run EmergencyWebPi.exe from the extracted folder.`n`nChecked paths:`n$checked",
    $appDisplayName,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

$temporaryRoots = @($env:TEMP, $env:TMP) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
foreach ($temporaryRoot in $temporaryRoots) {
  if ($repoRoot.StartsWith($temporaryRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-AppLog "Refusing to run from temporary extraction path: $repoRoot"
    [System.Windows.Forms.MessageBox]::Show(
      "This release is running from a temporary extraction folder. Extract the complete ZIP to a normal folder such as Downloads, then run the app again.",
      $appDisplayName,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit 1
  }
}

Write-AppLog "Repository root resolved: $repoRoot"

$appVersion = "unknown"
$versionPath = Join-Path $repoRoot "docs/VERSION"
if (Test-Path $versionPath) {
  $candidateVersion = (Get-Content $versionPath -Raw).Trim()
  if (-not [string]::IsNullOrWhiteSpace($candidateVersion)) {
    $appVersion = $candidateVersion
  }
}
Write-AppLog "Application version resolved: $appVersion"

$buildScript = Join-Path $repoRoot "scripts/build-appliance-image.ps1"
$writeScript = Join-Path $repoRoot "scripts/create-sd.ps1"
$dynamicScript = Join-Path $repoRoot "scripts/create-sd-dynamic.ps1"

if (-not (Test-Path $buildScript) -or -not (Test-Path $writeScript) -or -not (Test-Path $dynamicScript)) {
  Write-AppLog "Required build scripts are missing from the resolved repository root."
  [System.Windows.Forms.MessageBox]::Show(
    "Required scripts are missing. Ensure this portable folder is inside the repository root.",
    $appDisplayName,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

Write-AppLog "Required builder scripts found."

function Quote-Arg {
  param([Parameter(Mandatory = $true)][string]$Value)
  return '"' + $Value.Replace('"', '""') + '"'
}

function New-ProcessResult {
  param(
    [int]$ExitCode,
    [string]$Output
  )

  return [PSCustomObject]@{
    ExitCode = $ExitCode
    Output = $Output
  }
}

function Invoke-PowerShellScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $quotedScript = Quote-Arg -Value $ScriptPath
  $argLine = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $quotedScript)
  foreach ($arg in $Arguments) {
    $argLine += $arg
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.Arguments = ($argLine -join " ")
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $repoRoot

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  return New-ProcessResult -ExitCode $proc.ExitCode -Output (($stdout + "`r`n" + $stderr).Trim())
}

function To-Absolute {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return ""
  }

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
}

function Get-PinnedBaseImageInfo {
  $manifestPath = Join-Path $repoRoot "config/base-image.json"
  try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($manifest.name) -or $manifest.installedSizeBytes -le 0) {
      throw "Pinned base-image manifest is incomplete."
    }
    return $manifest
  } catch {
    throw "Unable to read pinned Raspberry Pi OS base-image manifest: $($_.Exception.Message)"
  }
}

function Get-ApplianceRequiredBytes {
  param([Parameter(Mandatory = $true)][Int64]$ContentBytes)

  $baseBytes = [int64](Get-PinnedBaseImageInfo).installedSizeBytes
  [int64]$oneGiB = 1GB
  [int64]$minimumZimPartitionBytes = 8GB
  [int64]$zimPartitionBytes = [Math]::Max(
    $minimumZimPartitionBytes,
    [Math]::Ceiling(($ContentBytes + $oneGiB) / $oneGiB) * $oneGiB
  )

  return $baseBytes + $zimPartitionBytes
}

function Resolve-ZimFileName {
  param([Parameter(Mandatory = $true)][string]$Url)

  $name = [System.IO.Path]::GetFileName($Url)
  if ($name.EndsWith(".torrent", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $name.Substring(0, $name.Length - 8)
  }

  return $name
}

function Get-CatalogItem {
  param([Parameter(Mandatory = $true)][string]$Url)

  $catalogPath = Join-Path $repoRoot "config/content-catalog.json"
  try {
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
    $fileName = Resolve-ZimFileName -Url $Url
    $metadata = $catalog.PSObject.Properties[$fileName].Value
    if ($null -ne $metadata) {
      $size = [int64]$metadata.estimatedBytes
      return [PSCustomObject]@{
        Url = $Url
        Name = $metadata.name
        Description = $metadata.description
        EstimatedBytes = $size
        LearnMoreUrl = $metadata.learnMoreUrl
        Display = "{0} - {1}" -f $metadata.name, (Format-Bytes -Bytes $size)
      }
    }
  } catch {
  }

  return [PSCustomObject]@{
    Url = $Url
    Name = Resolve-ZimFileName -Url $Url
    Description = "Offline library content"
    EstimatedBytes = [int64]0
    LearnMoreUrl = "https://kiwix.org/en/catalog/"
    Display = Resolve-ZimFileName -Url $Url
  }
}

function Open-LearnMoreUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [System.Windows.Forms.IWin32Window]$Owner = $null
  )

  $uri = $null
  $validUrl = [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -and
    $uri.Scheme -in @("http", "https")
  if (-not $validUrl) {
    [System.Windows.Forms.MessageBox]::Show(
      $Owner,
      "This library does not have a valid Learn More link.",
      "Emergency Web Pi",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return
  }

  try {
    Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
  } catch {
    [System.Windows.Forms.MessageBox]::Show(
      $Owner,
      "Could not open the Learn More link: $($_.Exception.Message)",
      "Emergency Web Pi",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  }
}

function Get-ProfileLabel {
  param([Parameter(Mandatory = $true)][string]$Path)

  switch ([System.IO.Path]::GetFileNameWithoutExtension($Path)) {
    "emergency-medical-zimlist" { return "Emergency & Medical" }
    "essential-web-zimlist" { return "Essential Web" }
    "practical-repair-zimlist" { return "Practical & Repair" }
    "medical-survival-zimlist" { return "Everything - Complete library" }
    default { return [System.IO.Path]::GetFileNameWithoutExtension($Path) }
  }
}

function Get-ProfileDescription {
  param([Parameter(Mandatory = $true)][string]$Path)

  switch ([System.IO.Path]::GetFileNameWithoutExtension($Path)) {
    "emergency-medical-zimlist" { return "First aid, emergency medicine, disaster response, and recovery guidance." }
    "essential-web-zimlist" { return "English and Dutch Wikipedia for broad everyday reference." }
    "practical-repair-zimlist" { return "Repair manuals, DIY, mechanics, woodworking, and Raspberry Pi help." }
    "medical-survival-zimlist" { return "All available emergency, medical, reference, repair, and practical knowledge libraries." }
    default { return "Offline library collection." }
  }
}

function Read-ProfileEntriesFromFile {
  param([Parameter(Mandatory = $true)][string]$ProfileFile)

  if (-not (Test-Path $ProfileFile)) {
    throw "Profile file not found: $ProfileFile"
  }

  $items = @()
  foreach ($line in Get-Content $ProfileFile) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    $items += $trimmed
  }

  if ($items.Count -eq 0) {
    throw "Profile has no usable entries: $ProfileFile"
  }

  return $items
}

function Format-Bytes {
  param([double]$Bytes)

  if ($Bytes -lt 1KB) { return "{0:N0} B" -f $Bytes }
  if ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
  if ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
  if ($Bytes -lt 1TB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
  return "{0:N2} TB" -f ($Bytes / 1TB)
}

function Get-PreflightEstimate {
  param(
    [Parameter(Mandatory = $true)][string[]]$Entries,
    [Parameter(Mandatory = $true)][string]$CacheDir,
    [string]$BaseImagePath,
    [bool]$AutoFetch,
    [string]$ReleaseRepo,
    [int]$DiskNumber = -1
  )

  $knownContentBytes = [int64]0
  $unknownCount = 0
  $downloadBytes = [int64]0
  $cachedCount = 0
  $catalogPath = Join-Path $repoRoot "config/content-catalog.json"
  $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json

  $resolvedCache = To-Absolute -PathValue $CacheDir
  if (-not (Test-Path $resolvedCache)) {
    New-Item -ItemType Directory -Path $resolvedCache | Out-Null
  }

  foreach ($url in $Entries) {
    $name = Resolve-ZimFileName -Url $url
    $catalogItem = $catalog.PSObject.Properties[$name].Value
    if ($null -eq $catalogItem -or $catalogItem.estimatedBytes -le 0) {
      throw "Content catalog is missing a verified size for: $name"
    }
    [int64]$estimatedSize = $catalogItem.estimatedBytes
    $cachePath = Join-Path $resolvedCache $name

    if (Test-Path $cachePath -PathType Leaf) {
      $size = (Get-Item $cachePath).Length
      if ($size -gt 0) {
        $knownContentBytes += $estimatedSize
        $cachedCount += 1
        continue
      }
    }

    $knownContentBytes += $estimatedSize
    $downloadBytes += $estimatedSize
  }

  $baseBytes = [int64]0
  $resolvedBase = To-Absolute -PathValue $BaseImagePath
  if (-not [string]::IsNullOrWhiteSpace($resolvedBase) -and (Test-Path $resolvedBase -PathType Leaf)) {
    $baseBytes = (Get-Item $resolvedBase).Length
  } else {
    $baseBytes = [int64](Get-PinnedBaseImageInfo).installedSizeBytes
  }

  $requiredBytes = Get-ApplianceRequiredBytes -ContentBytes $knownContentBytes

  $diskBytes = $null
  $fits = $null
  if ($DiskNumber -ge 0) {
    try {
      $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
      $diskBytes = [int64]$disk.Size
      $fits = ($requiredBytes -le $diskBytes)
    } catch {
      $diskBytes = $null
      $fits = $null
    }
  }

  return [PSCustomObject]@{
    BaseBytes = $baseBytes
    KnownContentBytes = $knownContentBytes
    DownloadBytes = $downloadBytes
    UnknownCount = $unknownCount
    CachedCount = $cachedCount
    RequiredBytes = $requiredBytes
    DiskBytes = $diskBytes
    Fits = $fits
  }
}

function Get-WizardRequiredBytes {
  param([Parameter(Mandatory = $true)]$Items)

  [int64]$contentBytes = 0
  foreach ($item in $Items) {
    $contentBytes += [int64]$item.EstimatedBytes
  }

  return Get-ApplianceRequiredBytes -ContentBytes $contentBytes
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $appDisplayName
$form.Size = New-Object System.Drawing.Size(1080, 920)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$script:normalLaunch = $false

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font
$script:uiSurface = [System.Drawing.Color]::FromArgb(248, 250, 252)
$script:uiBorder = [System.Drawing.Color]::FromArgb(203, 213, 225)
$script:uiPrimary = [System.Drawing.Color]::FromArgb(15, 107, 157)
$script:uiText = [System.Drawing.Color]::FromArgb(31, 41, 55)

function Set-PrimaryButtonStyle {
  param([Parameter(Mandatory = $true)][System.Windows.Forms.Button]$Button)

  $Button.FlatStyle = "Flat"
  $Button.FlatAppearance.BorderSize = 0
  $Button.BackColor = $script:uiPrimary
  $Button.ForeColor = [System.Drawing.Color]::White
  $Button.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
}

function Set-SecondaryButtonStyle {
  param([Parameter(Mandatory = $true)][System.Windows.Forms.Button]$Button)

  $Button.FlatStyle = "Flat"
  $Button.FlatAppearance.BorderColor = $script:uiBorder
  $Button.BackColor = [System.Drawing.Color]::White
  $Button.ForeColor = $script:uiText
}

$y = 20

function Add-Label {
  param([string]$Text, [int]$Top)
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Left = 20
  $label.Top = $Top
  $label.Width = 220
  $form.Controls.Add($label)
  return $label
}

function Add-TextBox {
  param([string]$DefaultText, [int]$Top)
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Left = 240
  $tb.Top = $Top - 3
  $tb.Width = 700
  $tb.Text = $DefaultText
  $form.Controls.Add($tb)
  return $tb
}

function Add-BrowseButton {
  param([int]$Top)
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = "Browse"
  $btn.Left = 950
  $btn.Top = $Top - 4
  $btn.Width = 90
  $form.Controls.Add($btn)
  return $btn
}

$lblBaseImage = Add-Label -Text "Raspberry Pi OS Base Image" -Top $y
$txtBase = Add-TextBox -DefaultText "" -Top $y
$btnBase = Add-BrowseButton -Top $y
$y += 40

$lblManifestPath = Add-Label -Text "Manifest Path" -Top $y
$txtManifestPath = Add-TextBox -DefaultText (Join-Path $workspaceDirectory "appliance.img.manifest.json") -Top $y
$btnManifest = Add-BrowseButton -Top $y
$y += 40

$lblConfig = Add-Label -Text "Config JSON" -Top $y
$txtConfig = Add-TextBox -DefaultText "config/appliance.example.json" -Top $y
$btnConfig = Add-BrowseButton -Top $y
$y += 40

$lblZimDir = Add-Label -Text "ZIM Source Dir" -Top $y
$txtZimDir = Add-TextBox -DefaultText "" -Top $y
$btnZimDir = Add-BrowseButton -Top $y
$y += 40

$lblOutputImage = Add-Label -Text "Output Image Path" -Top $y
$txtImagePath = Add-TextBox -DefaultText (Join-Path $workspaceDirectory "appliance.img") -Top $y
$y += 40

$lblProfilePath = Add-Label -Text "Dynamic Profile List (file)" -Top $y
$txtProfilePath = Add-TextBox -DefaultText "profiles/medical-survival-zimlist.txt" -Top $y
$btnProfile = Add-BrowseButton -Top $y
$y += 40

$lblProfilePreset = Add-Label -Text "Profile Preset" -Top $y
$cmbProfiles = New-Object System.Windows.Forms.ComboBox
$cmbProfiles.Left = 240
$cmbProfiles.Top = $y - 3
$cmbProfiles.Width = 540
$cmbProfiles.DropDownStyle = "DropDownList"
$form.Controls.Add($cmbProfiles)

$btnRefreshProfiles = New-Object System.Windows.Forms.Button
$btnRefreshProfiles.Text = "Refresh"
$btnRefreshProfiles.Left = 790
$btnRefreshProfiles.Top = $y - 4
$btnRefreshProfiles.Width = 70
$form.Controls.Add($btnRefreshProfiles)

$btnLoadProfile = New-Object System.Windows.Forms.Button
$btnLoadProfile.Text = "Load Items"
$btnLoadProfile.Left = 870
$btnLoadProfile.Top = $y - 4
$btnLoadProfile.Width = 170
$form.Controls.Add($btnLoadProfile)
$y += 40

$lblProfileItems = Add-Label -Text "Profile Items (checked = include)" -Top $y
$y += 22

$lstProfileItems = New-Object System.Windows.Forms.CheckedListBox
$lstProfileItems.Left = 240
$lstProfileItems.Top = $y
$lstProfileItems.Width = 800
$lstProfileItems.Height = 130
$lstProfileItems.CheckOnClick = $false
$lstProfileItems.DisplayMember = "Display"
$form.Controls.Add($lstProfileItems)
$y += 140

$chkUsePicker = New-Object System.Windows.Forms.CheckBox
$chkUsePicker.Text = "Use checked profile items for dynamic build"
$chkUsePicker.Left = 240
$chkUsePicker.Top = $y
$chkUsePicker.Width = 330
$chkUsePicker.Checked = $true
$form.Controls.Add($chkUsePicker)

$lblMainContentInfo = New-Object System.Windows.Forms.Label
$lblMainContentInfo.Left = 240
$lblMainContentInfo.Top = $chkUsePicker.Top + 2
$lblMainContentInfo.Width = 800
$lblMainContentInfo.Height = 22
$form.Controls.Add($lblMainContentInfo)
$y += 30

$lblCacheDir = Add-Label -Text "Dynamic Cache Dir" -Top $y
$txtCacheDir = Add-TextBox -DefaultText (Join-Path $workspaceDirectory "zim-cache") -Top $y
$y += 40

$lblDisk = Add-Label -Text "Target Disk Number" -Top $y
$txtDisk = Add-TextBox -DefaultText "" -Top $y
$y += 40

$chkAutoFetchBase = New-Object System.Windows.Forms.CheckBox
$chkAutoFetchBase.Text = "Offline appliance mode requires a local Raspberry Pi OS base image"
$chkAutoFetchBase.Left = 240
$chkAutoFetchBase.Top = $y
$chkAutoFetchBase.Width = 620
$chkAutoFetchBase.Checked = $false
$chkAutoFetchBase.Enabled = $false
$form.Controls.Add($chkAutoFetchBase)

$y += 30

$chkDownloadOnPi = New-Object System.Windows.Forms.CheckBox
$chkDownloadOnPi.Text = "Recommended: download selected catalogs on first boot"
$chkDownloadOnPi.Left = 240
$chkDownloadOnPi.Top = $y
$chkDownloadOnPi.Width = 700
$chkDownloadOnPi.Checked = $true
$chkDownloadOnPi.Enabled = $false
$form.Controls.Add($chkDownloadOnPi)

$y += 30

$lblReleaseRepo = Add-Label -Text "Release Repo" -Top $y
$txtReleaseRepo = Add-TextBox -DefaultText "MikeyMan83/emergency-web-pi" -Top $y
$y += 40

$btnToggleAdvanced = New-Object System.Windows.Forms.Button
$btnToggleAdvanced.Text = "Show Advanced Settings"
$btnToggleAdvanced.Left = 20
$btnToggleAdvanced.Top = $y - 32
$btnToggleAdvanced.Width = 220
$form.Controls.Add($btnToggleAdvanced)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Check Prereqs"
$btnCheck.Left = 20
$btnCheck.Top = $y
$btnCheck.Width = 120
$form.Controls.Add($btnCheck)

$btnWizard = New-Object System.Windows.Forms.Button
$btnWizard.Text = "Start End-User Wizard"
$btnWizard.Left = 250
$btnWizard.Top = $y - 32
$btnWizard.Width = 160
$form.Controls.Add($btnWizard)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = "Build Image"
$btnBuild.Left = 150
$btnBuild.Top = $y
$btnBuild.Width = 120
$form.Controls.Add($btnBuild)

$btnWrite = New-Object System.Windows.Forms.Button
$btnWrite.Text = "Write SD"
$btnWrite.Left = 280
$btnWrite.Top = $y
$btnWrite.Width = 120
$form.Controls.Add($btnWrite)

$btnEstimate = New-Object System.Windows.Forms.Button
$btnEstimate.Text = "Estimate Size"
$btnEstimate.Left = 410
$btnEstimate.Top = $y
$btnEstimate.Width = 120
$form.Controls.Add($btnEstimate)

$btnDynamic = New-Object System.Windows.Forms.Button
$btnDynamic.Text = "Step 3: Build && Flash SD Card"
$btnDynamic.Left = 540
$btnDynamic.Top = $y
$btnDynamic.Width = 240
$form.Controls.Add($btnDynamic)

$btnDisks = New-Object System.Windows.Forms.Button
$btnDisks.Text = "Refresh SD Cards"
$btnDisks.Left = 790
$btnDisks.Top = $y
$btnDisks.Width = 130
$form.Controls.Add($btnDisks)

$btnArtifacts = New-Object System.Windows.Forms.Button
$btnArtifacts.Text = "Open Workspace"
$btnArtifacts.Left = 930
$btnArtifacts.Top = $y
$btnArtifacts.Width = 110
$form.Controls.Add($btnArtifacts)

$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = "About && Licenses"
$btnAbout.Left = 150
$btnAbout.Top = $y
$btnAbout.Width = 140
$form.Controls.Add($btnAbout)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Exit"
$btnExit.Left = 20
$btnExit.Top = $y
$btnExit.Width = 120
$form.Controls.Add($btnExit)

$y += 50

$lblIntro = New-Object System.Windows.Forms.Label
$lblIntro.Left = 20
$lblIntro.Top = 12
$lblIntro.Width = 1020
$lblIntro.Height = 32
$lblIntro.Text = "Pick survival content, pick SD card, then build. Advanced internals are hidden by default."
$form.Controls.Add($lblIntro)

$lblStep1 = New-Object System.Windows.Forms.Label
$lblStep1.Left = 20
$lblStep1.Top = $lblProfilePreset.Top
$lblStep1.Width = 220
$lblStep1.Text = "Step 1: Select Content"
$form.Controls.Add($lblStep1)

$lblStep2 = New-Object System.Windows.Forms.Label
$lblStep2.Left = 20
$lblStep2.Top = $lblDisk.Top
$lblStep2.Width = 220
$lblStep2.Text = "Step 2: Select SD Card"
$form.Controls.Add($lblStep2)

$cmbDisks = New-Object System.Windows.Forms.ComboBox
$cmbDisks.Left = 240
$cmbDisks.Top = $lblDisk.Top - 3
$cmbDisks.Width = 540
$cmbDisks.DropDownStyle = "DropDownList"
$cmbDisks.DisplayMember = "Label"
$form.Controls.Add($cmbDisks)

$btnDiskRefreshInline = New-Object System.Windows.Forms.Button
$btnDiskRefreshInline.Text = "Refresh"
$btnDiskRefreshInline.Left = 790
$btnDiskRefreshInline.Top = $lblDisk.Top - 4
$btnDiskRefreshInline.Width = 90
$form.Controls.Add($btnDiskRefreshInline)

$lblProfilePreset.Text = "Step 1: Select Content Profile"
$lblProfileItems.Text = "Catalog Items (checked = include)"
$lblDisk.Visible = $false
$txtDisk.Visible = $false
$lblStep2.Text = "Step 2: Select SD Card"
$btnEstimate.Text = "Estimate Required SD Size"
$btnDynamic.Text = "Step 3: Build && Flash SD Card"
$btnWizard.Text = "Quick Wizard"
$chkUsePicker.Checked = $true
$chkUsePicker.Visible = $false

# Default to offline-ready prebuilt content; first-boot download remains available as an advanced option.
$chkDownloadOnPi.Checked = $false

$advancedControls = @(
  $lblBaseImage, $txtBase, $btnBase,
  $lblManifestPath, $txtManifestPath, $btnManifest,
  $lblConfig, $txtConfig, $btnConfig,
  $lblZimDir, $txtZimDir, $btnZimDir,
  $lblOutputImage, $txtImagePath,
  $lblProfilePath, $txtProfilePath, $btnProfile,
  $lblCacheDir, $txtCacheDir,
  $chkAutoFetchBase,
  $chkDownloadOnPi,
  $lblReleaseRepo, $txtReleaseRepo,
  $btnBuild, $btnWrite, $btnCheck
)

$showAdvanced = $false
foreach ($ctrl in $advancedControls) {
  $ctrl.Visible = $showAdvanced
}

function Set-AdvancedVisibility {
  param([bool]$Visible)

  $script:showAdvanced = $Visible
  foreach ($ctrl in $advancedControls) {
    $ctrl.Visible = $Visible
  }

  if ($Visible) {
    $btnToggleAdvanced.Text = "Hide Advanced Settings"
    Add-Log "Advanced settings shown."
  } else {
    $btnToggleAdvanced.Text = "Show Advanced Settings"
    Add-Log "Advanced settings hidden."
  }
}

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Left = 20
$txtLog.Top = $y
$txtLog.Width = 1020
$txtLog.Height = 300
$form.Controls.Add($txtLog)

function Add-Log {
  param([string]$Text)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $txtLog.AppendText("[$stamp] $Text`r`n")
  Write-AppLog $Text
}

function Move-DeveloperControl {
  param(
    [Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Control,
    [Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Parent,
    [int]$Left,
    [int]$Top,
    [int]$Width = 0
  )

  $Parent.Controls.Add($Control)
  $Control.Left = $Left
  $Control.Top = $Top
  if ($Width -gt 0) {
    $Control.Width = $Width
  }
  $Control.Visible = $true
}

function Show-DeveloperTools {
  Write-AppLog "Opening Developer Tools workspace."

  $developer = New-Object System.Windows.Forms.Form
  $developer.Text = "$appDisplayName - Developer Tools"
  $developer.ClientSize = New-Object System.Drawing.Size(1040, 700)
  $developer.StartPosition = "CenterScreen"
  $developer.Font = $font
  $developer.MinimizeBox = $false
  $developer.BackColor = $script:uiSurface
  $developer.ForeColor = $script:uiText

  $heading = New-Object System.Windows.Forms.Label
  $heading.Text = "Developer Tools"
  $heading.Left = 20
  $heading.Top = 16
  $heading.AutoSize = $true
  $heading.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
  $developer.Controls.Add($heading)

  $subheading = New-Object System.Windows.Forms.Label
  $subheading.Text = "Advanced appliance builder, diagnostics, and direct recovery workflows."
  $subheading.Left = 22
  $subheading.Top = 48
  $subheading.AutoSize = $true
  $developer.Controls.Add($subheading)

  $tabs = New-Object System.Windows.Forms.TabControl
  $tabs.Left = 20
  $tabs.Top = 78
  $tabs.Width = 1000
  $tabs.Height = 560
  $tabs.Appearance = "Buttons"
  $tabs.SizeMode = "Fixed"
  $tabs.ItemSize = New-Object System.Drawing.Size(120, 30)
  $developer.Controls.Add($tabs)

  $buildTab = New-Object System.Windows.Forms.TabPage
  $buildTab.Text = "Build"
  $contentTab = New-Object System.Windows.Forms.TabPage
  $contentTab.Text = "Content"
  $outputTab = New-Object System.Windows.Forms.TabPage
  $outputTab.Text = "SD & Output"
  $diagnosticsTab = New-Object System.Windows.Forms.TabPage
  $diagnosticsTab.Text = "Diagnostics"
  [void]$tabs.TabPages.AddRange(@($buildTab, $contentTab, $outputTab, $diagnosticsTab))

  $systemLabel = New-Object System.Windows.Forms.Label
  $systemLabel.Text = "Base system"
  $systemLabel.Left = 24
  $systemLabel.Top = 24
  $systemLabel.AutoSize = $true
  $systemLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
  $buildTab.Controls.Add($systemLabel)

  $baseInfo = Get-PinnedBaseImageInfo
  $systemDetail = New-Object System.Windows.Forms.Label
  $systemDetail.Text = "$($baseInfo.name) ($($baseInfo.architecture), $($baseInfo.releaseDate))`r`nAutomatically managed and SHA-256 verified."
  $systemDetail.Left = 24
  $systemDetail.Top = 52
  $systemDetail.Width = 650
  $systemDetail.Height = 42
  $buildTab.Controls.Add($systemDetail)

  Move-DeveloperControl -Control $btnCheck -Parent $buildTab -Left 24 -Top 120 -Width 150
  $btnCheck.Text = "Check prerequisites"
  Set-SecondaryButtonStyle -Button $btnCheck
  Move-DeveloperControl -Control $btnBuild -Parent $buildTab -Left 184 -Top 120 -Width 130
  $btnBuild.Text = "Build image"
  Set-PrimaryButtonStyle -Button $btnBuild

  $script:developerStatus = New-Object System.Windows.Forms.Label
  $script:developerStatus.Left = 24
  $script:developerStatus.Top = 158
  $script:developerStatus.Width = 900
  $script:developerStatus.Height = 26
  $script:developerStatus.Text = "Prerequisites have not been checked."
  $buildTab.Controls.Add($script:developerStatus)

  $advancedConfig = New-Object System.Windows.Forms.CheckBox
  $advancedConfig.Text = "Show raw build configuration"
  $advancedConfig.Left = 24
  $advancedConfig.Top = 194
  $advancedConfig.AutoSize = $true
  $buildTab.Controls.Add($advancedConfig)

  $buildRawControls = @($lblBaseImage, $txtBase, $btnBase, $lblConfig, $txtConfig, $btnConfig, $lblZimDir, $txtZimDir, $btnZimDir)
  Move-DeveloperControl -Control $lblBaseImage -Parent $buildTab -Left 24 -Top 230 -Width 180
  Move-DeveloperControl -Control $txtBase -Parent $buildTab -Left 220 -Top 227 -Width 600
  Move-DeveloperControl -Control $btnBase -Parent $buildTab -Left 832 -Top 227 -Width 110
  Move-DeveloperControl -Control $lblConfig -Parent $buildTab -Left 24 -Top 270 -Width 180
  Move-DeveloperControl -Control $txtConfig -Parent $buildTab -Left 220 -Top 267 -Width 600
  Move-DeveloperControl -Control $btnConfig -Parent $buildTab -Left 832 -Top 267 -Width 110
  Move-DeveloperControl -Control $lblZimDir -Parent $buildTab -Left 24 -Top 310 -Width 180
  Move-DeveloperControl -Control $txtZimDir -Parent $buildTab -Left 220 -Top 307 -Width 600
  Move-DeveloperControl -Control $btnZimDir -Parent $buildTab -Left 832 -Top 307 -Width 110
  foreach ($control in $buildRawControls) { $control.Visible = $false }
  $advancedConfig.Add_CheckedChanged({ foreach ($control in $buildRawControls) { $control.Visible = $advancedConfig.Checked } })

  Move-DeveloperControl -Control $lblProfilePreset -Parent $contentTab -Left 24 -Top 24 -Width 180
  $lblProfilePreset.Text = "Profile"
  Move-DeveloperControl -Control $cmbProfiles -Parent $contentTab -Left 220 -Top 21 -Width 520
  Move-DeveloperControl -Control $btnRefreshProfiles -Parent $contentTab -Left 750 -Top 21 -Width 85
  Move-DeveloperControl -Control $btnLoadProfile -Parent $contentTab -Left 845 -Top 21 -Width 110
  Set-SecondaryButtonStyle -Button $btnRefreshProfiles
  Set-SecondaryButtonStyle -Button $btnLoadProfile
  Move-DeveloperControl -Control $lblMainContentInfo -Parent $contentTab -Left 220 -Top 60 -Width 720
  $lblMainContentInfo.AutoSize = $false
  $lblMainContentInfo.Height = 42
  Move-DeveloperControl -Control $lstProfileItems -Parent $contentTab -Left 220 -Top 112 -Width 720
  $lstProfileItems.Height = 270
  Move-DeveloperControl -Control $lblProfileItems -Parent $contentTab -Left 24 -Top 112 -Width 180
  $lblProfileItems.Text = "Libraries"

  $contentAdvanced = New-Object System.Windows.Forms.CheckBox
  $contentAdvanced.Text = "Show profile and cache paths"
  $contentAdvanced.Left = 220
  $contentAdvanced.Top = 402
  $contentAdvanced.AutoSize = $true
  $contentTab.Controls.Add($contentAdvanced)
  $contentRawControls = @($lblProfilePath, $txtProfilePath, $btnProfile, $lblCacheDir, $txtCacheDir)
  Move-DeveloperControl -Control $lblProfilePath -Parent $contentTab -Left 24 -Top 438 -Width 180
  Move-DeveloperControl -Control $txtProfilePath -Parent $contentTab -Left 220 -Top 435 -Width 720
  Move-DeveloperControl -Control $btnProfile -Parent $contentTab -Left 220 -Top 472 -Width 110
  Move-DeveloperControl -Control $lblCacheDir -Parent $contentTab -Left 24 -Top 510 -Width 180
  Move-DeveloperControl -Control $txtCacheDir -Parent $contentTab -Left 220 -Top 507 -Width 720
  foreach ($control in $contentRawControls) { $control.Visible = $false }
  $contentAdvanced.Add_CheckedChanged({ foreach ($control in $contentRawControls) { $control.Visible = $contentAdvanced.Checked } })

  $sdLabel = New-Object System.Windows.Forms.Label
  $sdLabel.Text = "Target SD card"
  $sdLabel.Left = 24
  $sdLabel.Top = 24
  $sdLabel.AutoSize = $true
  $sdLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
  $outputTab.Controls.Add($sdLabel)
  Move-DeveloperControl -Control $cmbDisks -Parent $outputTab -Left 24 -Top 58 -Width 700
  Move-DeveloperControl -Control $btnDiskRefreshInline -Parent $outputTab -Left 736 -Top 58 -Width 120
  Set-SecondaryButtonStyle -Button $btnDiskRefreshInline
  Move-DeveloperControl -Control $btnEstimate -Parent $outputTab -Left 24 -Top 112 -Width 160
  $btnEstimate.Text = "Estimate capacity"
  Set-SecondaryButtonStyle -Button $btnEstimate
  Move-DeveloperControl -Control $btnDynamic -Parent $outputTab -Left 196 -Top 112 -Width 220
  $btnDynamic.Text = "Build & flash selected SD"
  Set-PrimaryButtonStyle -Button $btnDynamic
  Move-DeveloperControl -Control $btnWrite -Parent $outputTab -Left 428 -Top 112 -Width 180
  $btnWrite.Text = "Write prepared image"
  Set-SecondaryButtonStyle -Button $btnWrite

  $outputAdvanced = New-Object System.Windows.Forms.CheckBox
  $outputAdvanced.Text = "Show output and manifest paths"
  $outputAdvanced.Left = 24
  $outputAdvanced.Top = 172
  $outputAdvanced.AutoSize = $true
  $outputTab.Controls.Add($outputAdvanced)
  $outputRawControls = @($lblOutputImage, $txtImagePath, $lblManifestPath, $txtManifestPath, $btnManifest)
  Move-DeveloperControl -Control $lblOutputImage -Parent $outputTab -Left 24 -Top 210 -Width 180
  Move-DeveloperControl -Control $txtImagePath -Parent $outputTab -Left 220 -Top 207 -Width 720
  Move-DeveloperControl -Control $lblManifestPath -Parent $outputTab -Left 24 -Top 250 -Width 180
  Move-DeveloperControl -Control $txtManifestPath -Parent $outputTab -Left 220 -Top 247 -Width 600
  Move-DeveloperControl -Control $btnManifest -Parent $outputTab -Left 832 -Top 247 -Width 110
  foreach ($control in $outputRawControls) { $control.Visible = $false }
  $outputAdvanced.Add_CheckedChanged({ foreach ($control in $outputRawControls) { $control.Visible = $outputAdvanced.Checked } })

  $diagnosticActions = New-Object System.Windows.Forms.Panel
  $diagnosticActions.Dock = "Bottom"
  $diagnosticActions.Height = 58
  $diagnosticsTab.Controls.Add($diagnosticActions)
  $txtLog.Parent = $diagnosticsTab
  $txtLog.Dock = "Fill"
  $txtLog.Visible = $true
  Move-DeveloperControl -Control $btnArtifacts -Parent $diagnosticActions -Left 16 -Top 14 -Width 150
  Move-DeveloperControl -Control $btnAbout -Parent $diagnosticActions -Left 176 -Top 14 -Width 150
  Move-DeveloperControl -Control $btnExit -Parent $diagnosticActions -Left 830 -Top 14 -Width 110
  $btnExit.Text = "Close tools"
  $btnArtifacts.Text = "Open workspace"
  Set-SecondaryButtonStyle -Button $btnArtifacts
  Set-SecondaryButtonStyle -Button $btnAbout
  Set-SecondaryButtonStyle -Button $btnExit
  $btnExit.Add_Click({ $developer.Close() })
  $diagnosticActions.BringToFront()

  $btnToggleAdvanced.Visible = $false
  $lblDisk.Visible = $false
  $txtDisk.Visible = $false
  $chkAutoFetchBase.Visible = $false
  $chkDownloadOnPi.Visible = $false
  $lblReleaseRepo.Visible = $false
  $txtReleaseRepo.Visible = $false

  [void]$developer.ShowDialog()
}

function Refresh-ProfilePicker {
  $profilesDir = Join-Path $repoRoot "profiles"
  $cmbProfiles.Items.Clear()

  if (-not (Test-Path $profilesDir)) {
    Add-Log "Profiles directory not found: $profilesDir"
    return
  }

  $files = Get-ChildItem -Path $profilesDir -File -Filter "*.txt" | Sort-Object Name
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($repoRoot.Length + 1)
    [void]$cmbProfiles.Items.Add($relative)
  }

  if ($cmbProfiles.Items.Count -gt 0) {
    $defaultProfile = "profiles\medical-survival-zimlist.txt"
    $defaultIndex = $cmbProfiles.Items.IndexOf($defaultProfile)
    $cmbProfiles.SelectedIndex = if ($defaultIndex -ge 0) { $defaultIndex } else { 0 }
  }
}

function Load-SelectedPresetItems {
  if ($cmbProfiles.SelectedItem -eq $null) {
    Add-Log "Profile load skipped: no profile preset selected."
    return
  }

  try {
    $profilePath = To-Absolute -PathValue ([string]$cmbProfiles.SelectedItem)
    $items = Read-ProfileEntriesFromFile -ProfileFile $profilePath

    $lstProfileItems.Items.Clear()
    foreach ($item in $items) {
      [void]$lstProfileItems.Items.Add((Get-CatalogItem -Url $item), $true)
    }

    $txtProfilePath.Text = [string]$cmbProfiles.SelectedItem
    Update-MainContentSummary
    Add-Log "Loaded $($items.Count) catalog item(s) from $(Get-ProfileLabel -Path $cmbProfiles.SelectedItem)."
  } catch {
    Add-Log "Failed to load preset items: $($_.Exception.Message)"
  }
}

function Update-MainContentSummary {
  [int64]$contentBytes = 0
  $selectedCount = 0
  $selectedItems = @()
  foreach ($checkedIndex in $lstProfileItems.CheckedIndices) {
    $item = $lstProfileItems.Items[$checkedIndex]
    $contentBytes += [int64]$item.EstimatedBytes
    $selectedCount += 1
    $selectedItems += $item
  }

  if ($selectedCount -eq 0) {
    $lblMainContentInfo.Text = "Select at least one library to continue."
    return
  }

  $requiredBytes = Get-WizardRequiredBytes -Items $selectedItems
  $profileDescription = Get-ProfileDescription -Path $cmbProfiles.SelectedItem
  $lblMainContentInfo.Text = "$profileDescription Selected: $selectedCount libraries, $(Format-Bytes -Bytes $contentBytes) content. Estimated minimum SD: $(Format-Bytes -Bytes $requiredBytes)."
}

function Resolve-EntriesForDynamicRun {
  if ($chkUsePicker.Checked -and $lstProfileItems.Items.Count -gt 0) {
    $selected = @()
    for ($i = 0; $i -lt $lstProfileItems.Items.Count; $i++) {
      if ($lstProfileItems.GetItemChecked($i)) {
        $selected += [string]$lstProfileItems.Items[$i].Url
      }
    }

    if ($selected.Count -eq 0) {
      throw "No profile items selected in picker."
    }

    return $selected
  }

  $profilePath = To-Absolute -PathValue $txtProfilePath.Text
  return Read-ProfileEntriesFromFile -ProfileFile $profilePath
}

function Write-GeneratedProfileFile {
  param([Parameter(Mandatory = $true)][string[]]$Entries)

  $generatedDir = Join-Path $workspaceDirectory "generated-profiles"
  if (-not (Test-Path $generatedDir)) {
    New-Item -ItemType Directory -Path $generatedDir | Out-Null
  }

  $filename = "dynamic-profile-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss")
  $outPath = Join-Path $generatedDir $filename
  Set-Content -Path $outPath -Value $Entries -Encoding utf8
  return $outPath
}

function Log-PreflightEstimate {
  param([Parameter(Mandatory = $true)]$Estimate)

  Add-Log "Preflight estimate:"
  Add-Log "  Base image:        $(Format-Bytes -Bytes $Estimate.BaseBytes)"
  Add-Log "  Known content:     $(Format-Bytes -Bytes $Estimate.KnownContentBytes)"
  Add-Log "  Estimated download:$(Format-Bytes -Bytes $Estimate.DownloadBytes)"
  Add-Log "  Cached items:      $($Estimate.CachedCount)"
  Add-Log "  Unknown-size items:$($Estimate.UnknownCount)"
  Add-Log "  Required SD size:  $(Format-Bytes -Bytes $Estimate.RequiredBytes)"

  if ($null -ne $Estimate.DiskBytes) {
    Add-Log "  Disk size:         $(Format-Bytes -Bytes $Estimate.DiskBytes)"
    if ($Estimate.Fits -eq $true) {
      Add-Log "  Capacity check:    OK"
    } elseif ($Estimate.Fits -eq $false) {
      Add-Log "  Capacity check:    TOO SMALL"
    }
  }
}

function Get-SelectableDisks {
  $all = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -gt 0 })
  $preferred = @($all | Where-Object { $_.BusType -in @("USB", "SD") })
  if ($preferred.Count -gt 0) {
    return @($preferred)
  }
  return @($all)
}

function Refresh-DiskPicker {
  $cmbDisks.Items.Clear()
  try {
    $disks = @(Get-SelectableDisks)
    foreach ($disk in $disks) {
      $label = "Disk {0} - {1} - {2} - {3}" -f $disk.Number, $disk.FriendlyName, (Format-Bytes -Bytes $disk.Size), $disk.BusType
      [void]$cmbDisks.Items.Add([PSCustomObject]@{ Label = $label; Number = [int]$disk.Number })
    }

    if ($cmbDisks.Items.Count -gt 0) {
      $cmbDisks.SelectedIndex = 0
      $txtDisk.Text = [string]$cmbDisks.SelectedItem.Number
    } else {
      $txtDisk.Text = ""
    }
  } catch {
    $txtDisk.Text = ""
    Add-Log "Failed to refresh disk picker: $($_.Exception.Message)"
  }
}

function Get-SelectedDiskNumber {
  if ($cmbDisks.SelectedItem -ne $null) {
    return [int]$cmbDisks.SelectedItem.Number
  }

  [int]$diskNum = -1
  if ([int]::TryParse($txtDisk.Text, [ref]$diskNum)) {
    return $diskNum
  }

  return -1
}

function Show-EndUserWizard {
  param(
    [Parameter(Mandatory = $true)][string[]]$ProfilePaths,
    [Parameter(Mandatory = $true)][string]$DefaultProfile,
    [AllowEmptyCollection()]$Disks = @(),
    [System.Windows.Forms.IWin32Window]$Owner = $null
  )

  $Disks = @($Disks)
  $wizard = New-Object System.Windows.Forms.Form
  Write-AppLog "Opening end-user wizard."
  $wizard.Text = "Emergency Web Pi Wizard"
  $wizard.ClientSize = New-Object System.Drawing.Size(980, 740)
  $wizard.StartPosition = "CenterParent"
  $wizard.FormBorderStyle = "FixedDialog"
  $wizard.MaximizeBox = $false
  $wizard.MinimizeBox = $false
  $wizard.Font = $font
  $wizard.BackColor = $script:uiSurface
  $wizard.ForeColor = $script:uiText

  $versionLabel = New-Object System.Windows.Forms.Label
  $versionLabel.Left = 760
  $versionLabel.Top = 18
  $versionLabel.Width = 190
  $versionLabel.Height = 24
  $versionLabel.Text = "Emergency Web Pi v$appVersion"
  $versionLabel.TextAlign = [System.Drawing.ContentAlignment]::TopRight
  $versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
  $wizard.Controls.Add($versionLabel)

  $wy = 16

  $lblIntro = New-Object System.Windows.Forms.Label
  $lblIntro.Left = 16
  $lblIntro.Top = $wy
  $lblIntro.Width = 720
  $lblIntro.Height = 44
  $lblIntro.Text = "Choose what you want available offline, how to install it, and which SD card to erase."
  $lblIntro.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
  $wizard.Controls.Add($lblIntro)
  $wy += 50

  $lblBase = New-Object System.Windows.Forms.Label
  $lblBase.Left = 16
  $lblBase.Top = $wy
  $lblBase.Width = 850
  $baseInfo = Get-PinnedBaseImageInfo
  $lblBase.Text = "Raspberry Pi OS: $($baseInfo.codename) ($($baseInfo.architecture), $($baseInfo.releaseDate)) - automatically downloaded and verified"
  $lblBase.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
  $wizard.Controls.Add($lblBase)
  $wy += 38

  $lblProfile = New-Object System.Windows.Forms.Label
  $lblProfile.Left = 16
  $lblProfile.Top = $wy
  $lblProfile.Width = 180
  $lblProfile.Text = "Choose a collection"
  $wizard.Controls.Add($lblProfile)

  $cmbWizardProfile = New-Object System.Windows.Forms.ComboBox
  $cmbWizardProfile.Left = 210
  $cmbWizardProfile.Top = $wy - 3
  $cmbWizardProfile.Width = 660
  $cmbWizardProfile.DropDownStyle = "DropDownList"
  $cmbWizardProfile.DisplayMember = "Label"
  foreach ($path in $ProfilePaths) {
    [void]$cmbWizardProfile.Items.Add([PSCustomObject]@{ Label = Get-ProfileLabel -Path $path; Path = $path })
  }
  if ($cmbWizardProfile.Items.Count -gt 0) {
    $defaultIndex = 0
    for ($index = 0; $index -lt $cmbWizardProfile.Items.Count; $index++) {
      if ($cmbWizardProfile.Items[$index].Path -eq $DefaultProfile) {
        $defaultIndex = $index
        break
      }
    }
    $cmbWizardProfile.SelectedIndex = $defaultIndex
  }
  $wizard.Controls.Add($cmbWizardProfile)
  $wy += 38

  $lblProfileInfo = New-Object System.Windows.Forms.Label
  $lblProfileInfo.Left = 210
  $lblProfileInfo.Top = $wy - 2
  $lblProfileInfo.Width = 740
  $lblProfileInfo.Height = 42
  $wizard.Controls.Add($lblProfileInfo)
  $wy += 40

  $lblItems = New-Object System.Windows.Forms.Label
  $lblItems.Left = 16
  $lblItems.Top = $wy
  $lblItems.Width = 180
  $lblItems.Text = "Fine-tune libraries"
  $wizard.Controls.Add($lblItems)

  $lstWizardItems = New-Object System.Windows.Forms.ListView
  $lstWizardItems.Left = 210
  $lstWizardItems.Top = $wy
  $lstWizardItems.Width = 740
  $lstWizardItems.Height = 210
  $lstWizardItems.View = [System.Windows.Forms.View]::Details
  $lstWizardItems.CheckBoxes = $true
  $lstWizardItems.FullRowSelect = $true
  $lstWizardItems.MultiSelect = $false
  [void]$lstWizardItems.Columns.Add("Library", 185)
  [void]$lstWizardItems.Columns.Add("Size", 100)
  [void]$lstWizardItems.Columns.Add("Description", 430)
  $wizard.Controls.Add($lstWizardItems)
  $wy += 220

  $btnAll = New-Object System.Windows.Forms.Button
  $btnAll.Text = "Select All"
  $btnAll.Left = 210
  $btnAll.Top = $wy
  $btnAll.Width = 100
  Set-SecondaryButtonStyle -Button $btnAll
  $wizard.Controls.Add($btnAll)

  $btnNone = New-Object System.Windows.Forms.Button
  $btnNone.Text = "Select None"
  $btnNone.Left = 320
  $btnNone.Top = $wy
  $btnNone.Width = 100
  Set-SecondaryButtonStyle -Button $btnNone
  $wizard.Controls.Add($btnNone)
  $wy += 36

  $lblSelection = New-Object System.Windows.Forms.Label
  $lblSelection.Left = 210
  $lblSelection.Top = $wy
  $lblSelection.Width = 740
  $lblSelection.Height = 24
  $wizard.Controls.Add($lblSelection)
  $wy += 28

  $wy += 42

  $lblDisk = New-Object System.Windows.Forms.Label
  $lblDisk.Left = 16
  $lblDisk.Top = $wy
  $lblDisk.Width = 180
  $lblDisk.Text = "Target SD disk"
  $wizard.Controls.Add($lblDisk)

  $cmbWizardDisk = New-Object System.Windows.Forms.ComboBox
  $cmbWizardDisk.Left = 210
  $cmbWizardDisk.Top = $wy - 3
  $cmbWizardDisk.Width = 740
  $cmbWizardDisk.DropDownStyle = "DropDownList"
  foreach ($disk in $Disks) {
    $label = "Disk {0} | {1} | {2} | {3}" -f $disk.Number, $disk.FriendlyName, (Format-Bytes -Bytes $disk.Size), $disk.BusType
    [void]$cmbWizardDisk.Items.Add([PSCustomObject]@{ Label = $label; Number = [int]$disk.Number; Size = [int64]$disk.Size })
  }
  if ($cmbWizardDisk.Items.Count -gt 0) {
    $cmbWizardDisk.SelectedIndex = 0
  }
  $cmbWizardDisk.DisplayMember = "Label"
  $wizard.Controls.Add($cmbWizardDisk)
  $wy += 38

  $lblMode = New-Object System.Windows.Forms.Label
  $lblMode.Left = 16
  $lblMode.Top = $wy
  $lblMode.Width = 180
  $lblMode.Text = "Content installation"
  $wizard.Controls.Add($lblMode)

  $optPrebuilt = New-Object System.Windows.Forms.RadioButton
  $optPrebuilt.Left = 210
  $optPrebuilt.Top = $wy
  $optPrebuilt.Width = 740
  $optPrebuilt.Checked = $true
  $optPrebuilt.Text = "Recommended: prebuild content now for an offline-ready first boot"
  $wizard.Controls.Add($optPrebuilt)
  $wy += 24

  $optFirstBoot = New-Object System.Windows.Forms.RadioButton
  $optFirstBoot.Left = 210
  $optFirstBoot.Top = $wy
  $optFirstBoot.Width = 740
  $optFirstBoot.Text = "Advanced: download selected content on first boot (Internet required once)"
  $wizard.Controls.Add($optFirstBoot)
  $wy += 28

  $chkUpstream = New-Object System.Windows.Forms.CheckBox
  $chkUpstream.Left = 230
  $chkUpstream.Top = $wy
  $chkUpstream.Width = 720
  $chkUpstream.Text = "Use home Wi-Fi for the FirstBoot download"
  $wizard.Controls.Add($chkUpstream)
  $wy += 28

  $lblUpstreamSsid = New-Object System.Windows.Forms.Label
  $lblUpstreamSsid.Left = 250
  $lblUpstreamSsid.Top = $wy
  $lblUpstreamSsid.Width = 120
  $lblUpstreamSsid.Text = "Wi-Fi name"
  $wizard.Controls.Add($lblUpstreamSsid)

  $txtUpstreamSsid = New-Object System.Windows.Forms.TextBox
  $txtUpstreamSsid.Left = 380
  $txtUpstreamSsid.Top = $wy - 3
  $txtUpstreamSsid.Width = 240
  $txtUpstreamSsid.Enabled = $false
  $wizard.Controls.Add($txtUpstreamSsid)

  $lblUpstreamPassword = New-Object System.Windows.Forms.Label
  $lblUpstreamPassword.Left = 640
  $lblUpstreamPassword.Top = $wy
  $lblUpstreamPassword.Width = 120
  $lblUpstreamPassword.Text = "Wi-Fi password"
  $wizard.Controls.Add($lblUpstreamPassword)

  $txtUpstreamPassword = New-Object System.Windows.Forms.TextBox
  $txtUpstreamPassword.Left = 770
  $txtUpstreamPassword.Top = $wy - 3
  $txtUpstreamPassword.Width = 180
  $txtUpstreamPassword.UseSystemPasswordChar = $true
  $txtUpstreamPassword.Enabled = $false
  $wizard.Controls.Add($txtUpstreamPassword)
  $chkUpstream.Add_CheckedChanged({
    $txtUpstreamSsid.Enabled = $optFirstBoot.Checked -and $chkUpstream.Checked
    $txtUpstreamPassword.Enabled = $optFirstBoot.Checked -and $chkUpstream.Checked
  })
  $wy += 38

  $updateUpstreamAvailability = {
    $firstBootSelected = $optFirstBoot.Checked
    $chkUpstream.Enabled = $firstBootSelected
    if (-not $firstBootSelected) {
      $chkUpstream.Checked = $false
      $txtUpstreamSsid.Text = ""
      $txtUpstreamPassword.Text = ""
    }
    $txtUpstreamSsid.Enabled = $firstBootSelected -and $chkUpstream.Checked
    $txtUpstreamPassword.Enabled = $firstBootSelected -and $chkUpstream.Checked
  }
  $optFirstBoot.Add_CheckedChanged($updateUpstreamAvailability)
  $optPrebuilt.Add_CheckedChanged($updateUpstreamAvailability)
  & $updateUpstreamAvailability

  $btnCancelWizard = New-Object System.Windows.Forms.Button
  $btnCancelWizard.Text = "Cancel"
  $btnCancelWizard.Left = 630
  $btnCancelWizard.Top = $wy
  $btnCancelWizard.Width = 100
  Set-SecondaryButtonStyle -Button $btnCancelWizard
  $wizard.Controls.Add($btnCancelWizard)

    $btnDeveloperTools = New-Object System.Windows.Forms.Button
    $btnDeveloperTools.Text = "Developer Tools"
    $btnDeveloperTools.Left = 740
    $btnDeveloperTools.Top = $wy
    $btnDeveloperTools.Width = 110
    Set-SecondaryButtonStyle -Button $btnDeveloperTools
    $wizard.Controls.Add($btnDeveloperTools)

  $btnStartWizard = New-Object System.Windows.Forms.Button
  $btnStartWizard.Text = "Estimate + Build"
  $btnStartWizard.Left = 830
  $btnStartWizard.Top = $wy
  $btnStartWizard.Width = 120
  Set-PrimaryButtonStyle -Button $btnStartWizard
  $wizard.Controls.Add($btnStartWizard)

  $result = $null
  $script:developerToolsRequested = $false

  $loadItems = {
    $lstWizardItems.Items.Clear()
    if ($cmbWizardProfile.SelectedItem -eq $null) {
      return
    }

    try {
      $profileAbs = To-Absolute -PathValue ([string]$cmbWizardProfile.SelectedItem.Path)
      $entries = Read-ProfileEntriesFromFile -ProfileFile $profileAbs
      [int64]$profileBytes = 0
      foreach ($entry in $entries) {
        $item = Get-CatalogItem -Url $entry
        $profileBytes += [int64]$item.EstimatedBytes
        $row = New-Object System.Windows.Forms.ListViewItem
        $row.Text = $item.Name
        [void]$row.SubItems.Add((Format-Bytes -Bytes $item.EstimatedBytes))
        [void]$row.SubItems.Add($item.Description)
        $row.Tag = $item
        $row.Checked = $true
        [void]$lstWizardItems.Items.Add($row)
      }
      $lblProfileInfo.Text = "$(Get-ProfileDescription -Path $cmbWizardProfile.SelectedItem.Path) Includes $($entries.Count) libraries, about $(Format-Bytes -Bytes $profileBytes). Uncheck anything you do not need below."
    } catch {
      [System.Windows.Forms.MessageBox]::Show(
        "Failed to load catalog preset: $($_.Exception.Message)",
        "Wizard",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      ) | Out-Null
    }
  }

  $cmbWizardProfile.add_SelectedIndexChanged($loadItems)
  & $loadItems

  $updateSelection = {
    [int64]$selectedBytes = 0
    $selectedCount = 0
    $selectedItems = @()
    foreach ($row in $lstWizardItems.CheckedItems) {
      $item = $row.Tag
      $selectedBytes += [int64]$item.EstimatedBytes
      $selectedCount += 1
      $selectedItems += $item
    }
    $requiredBytes = Get-WizardRequiredBytes -Items $selectedItems
    $capacityText = "Required SD: $(Format-Bytes -Bytes $requiredBytes)"
    if ($cmbWizardDisk.SelectedItem -ne $null) {
      $diskBytes = [int64]$cmbWizardDisk.SelectedItem.Size
      $state = if ($diskBytes -ge $requiredBytes) { "enough space" } else { "too small" }
      $capacityText += " | Selected card: $(Format-Bytes -Bytes $diskBytes) ($state)"
    }
    $lblSelection.Text = "Selected: $selectedCount items, $(Format-Bytes -Bytes $selectedBytes) | $capacityText"
  }

  $lstWizardItems.Add_ItemCheck({
    if ($wizard.IsHandleCreated) {
      $wizard.BeginInvoke([System.Action]$updateSelection) | Out-Null
    } else {
      & $updateSelection
    }
  })
  $cmbWizardDisk.Add_SelectedIndexChanged({ & $updateSelection })
  & $updateSelection

  $btnAll.Add_Click({
    for ($i = 0; $i -lt $lstWizardItems.Items.Count; $i++) {
      $lstWizardItems.Items[$i].Checked = $true
    }
  })

  $btnNone.Add_Click({
    for ($i = 0; $i -lt $lstWizardItems.Items.Count; $i++) {
      $lstWizardItems.Items[$i].Checked = $false
    }
  })

  $btnCancelWizard.Add_Click({
    $wizard.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $wizard.Close()
  })

  $btnDeveloperTools.Add_Click({
    Write-AppLog "Developer Tools requested from wizard."
    $script:developerToolsRequested = $true
    $wizard.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $wizard.Close()
  })

  $btnStartWizard.Add_Click({
    Write-AppLog "Wizard build requested."
    if ($cmbWizardProfile.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("Select a catalog preset.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    if ($cmbWizardDisk.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("No writable SD card is detected. Insert an SD card, then click Refresh SD Cards from Developer Tools or restart the wizard.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    $entries = @()
    foreach ($row in $lstWizardItems.CheckedItems) {
      if ($null -ne $row.Tag) {
        $entries += [string]$row.Tag.Url
      }
    }

    if ($entries.Count -eq 0) {
      [System.Windows.Forms.MessageBox]::Show("Select at least one catalog item.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    $selectedItems = @()
    foreach ($row in $lstWizardItems.CheckedItems) {
      $selectedItems += $row.Tag
    }
    $requiredBytes = Get-WizardRequiredBytes -Items $selectedItems
    if ([int64]$cmbWizardDisk.SelectedItem.Size -lt $requiredBytes) {
      [System.Windows.Forms.MessageBox]::Show("This SD card is too small. Choose a card with at least $(Format-Bytes -Bytes $requiredBytes).", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    $result = [PSCustomObject]@{
      Profile = [string]$cmbWizardProfile.SelectedItem.Path
      Entries = $entries
      DiskNumber = [int]$cmbWizardDisk.SelectedItem.Number
      ContentMode = if ($optPrebuilt.Checked) { "Prebuilt" } else { "FirstBoot" }
    }

    $wizard.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $wizard.Close()
  })

  $dialogResult = if ($null -eq $Owner) { $wizard.ShowDialog() } else { $wizard.ShowDialog($Owner) }
  Write-AppLog "End-user wizard closed with result: $dialogResult"
  if ($script:developerToolsRequested) {
    return [PSCustomObject]@{ DeveloperTools = $true }
  }
  if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
    return $null
  }

  return $result
}

$btnBase.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Image Files (*.img)|*.img|All Files (*.*)|*.*"
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtBase.Text = $dlg.FileName
  }
})

$btnManifest.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Manifest Files (*.json)|*.json|All Files (*.*)|*.*"
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtManifestPath.Text = $dlg.FileName
  }
})

$btnConfig.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtConfig.Text = $dlg.FileName
  }
})

$btnZimDir.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtZimDir.Text = $dlg.SelectedPath
  }
})

$btnProfile.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtProfilePath.Text = $dlg.FileName
  }
})

$btnRefreshProfiles.Add_Click({
  Refresh-ProfilePicker
  Add-Log "Profile preset list refreshed."
})

$cmbDisks.Add_SelectedIndexChanged({
  if ($cmbDisks.SelectedItem -ne $null) {
    $txtDisk.Text = [string]$cmbDisks.SelectedItem.Number
  }
  Update-MainContentSummary
})

$lstProfileItems.Add_ItemCheck({
  if ($form.IsHandleCreated) {
    $form.BeginInvoke([System.Action]{ Update-MainContentSummary }) | Out-Null
  } else {
    Update-MainContentSummary
  }
})

$btnDiskRefreshInline.Add_Click({
  Refresh-DiskPicker
  Add-Log "SD card list refreshed."
})

$btnToggleAdvanced.Add_Click({
  Set-AdvancedVisibility -Visible (-not $showAdvanced)
})

function Start-EndUserFlow {
  try {
    if ($cmbProfiles.Items.Count -eq 0) {
      Refresh-ProfilePicker
    }

    $profilePaths = @()
    foreach ($item in $cmbProfiles.Items) {
      $profilePaths += [string]$item
    }

    if ($profilePaths.Count -eq 0) {
      Add-Log "Wizard aborted: no profile presets found in profiles/*.txt"
      return
    }

    $disks = Get-SelectableDisks
    if ($disks.Count -eq 0) {
      Add-Log "No writable target disks found; opening wizard so the user can review content or open Developer Tools."
    }

    $defaultProfile = if ($cmbProfiles.SelectedItem) { [string]$cmbProfiles.SelectedItem } else { $profilePaths[0] }
    $wizardOwner = if ($script:normalLaunch) { $null } else { $form }
    $selection = Show-EndUserWizard -ProfilePaths $profilePaths -DefaultProfile $defaultProfile -Disks $disks -Owner $wizardOwner
    if ($null -eq $selection) {
      Add-Log "Wizard cancelled."
      if ($script:normalLaunch) {
        $form.Close()
      }
      return
    }

    if ($selection.DeveloperTools) {
      $script:normalLaunch = $false
      Show-DeveloperTools
      $form.Close()
      return
    }

    $txtDisk.Text = [string]$selection.DiskNumber
    for ($i = 0; $i -lt $cmbDisks.Items.Count; $i++) {
      if ([int]$cmbDisks.Items[$i].Number -eq [int]$selection.DiskNumber) {
        $cmbDisks.SelectedIndex = $i
        break
      }
    }
    $chkAutoFetchBase.Checked = $false
    $chkDownloadOnPi.Checked = $selection.ContentMode -eq "FirstBoot"
    $chkUsePicker.Checked = $true
    $cmbProfiles.SelectedItem = $selection.Profile
    $txtProfilePath.Text = $selection.Profile

    $lstProfileItems.Items.Clear()
    foreach ($entry in $selection.Entries) {
      [void]$lstProfileItems.Items.Add($entry, $true)
    }

    $estimate = Get-PreflightEstimate -Entries $selection.Entries -CacheDir $txtCacheDir.Text -BaseImagePath $txtBase.Text -AutoFetch $false -ReleaseRepo $txtReleaseRepo.Text -DiskNumber $selection.DiskNumber
    Log-PreflightEstimate -Estimate $estimate

    Add-Log "Wizard selection applied. Continuing with dynamic build."
    $btnDynamic.PerformClick()
  } catch {
    Add-Log "Wizard failed: $($_.Exception.Message)"
    Write-AppLog ("Wizard failed: {0}" -f $_.Exception.ToString())
    [System.Windows.Forms.MessageBox]::Show(
      "Emergency Web Pi could not open the setup wizard.`n`n$($_.Exception.Message)`n`nDiagnostic log:`n$logPath",
      $appDisplayName,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    if ($script:normalLaunch) {
      $form.Close()
    }
  }
}

$btnWizard.Add_Click({ Start-EndUserFlow })

$btnLoadProfile.Add_Click({
  Load-SelectedPresetItems
})

$btnCheck.Add_Click({
  Add-Log "Checking prerequisites"

  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $wslReady = $false
  if ($isAdmin) {
    Add-Log "PowerShell elevation: OK"
  } else {
    Add-Log "PowerShell elevation: REQUIRED for SD write"
  }

  try {
    $null = & wsl --version 2>$null
    if ($LASTEXITCODE -eq 0) {
      $wslReady = $true
      Add-Log "WSL detected"
    } else {
      Add-Log "WSL not detected; install with: wsl --install -d Ubuntu"
    }
  } catch {
    Add-Log "WSL not detected; install with: wsl --install -d Ubuntu"
  }

  $baseAbs = To-Absolute -PathValue $txtBase.Text
  if ([string]::IsNullOrWhiteSpace($baseAbs) -or -not (Test-Path $baseAbs)) {
    if ($chkAutoFetchBase.Checked) {
      Add-Log "Base image: will auto-fetch in dynamic mode"
    } else {
      Add-Log "Base image: missing"
    }
  } else {
    Add-Log "Base image: OK"
  }

  $manifestAbs = To-Absolute -PathValue $txtManifestPath.Text
  if ([string]::IsNullOrWhiteSpace($manifestAbs) -or -not (Test-Path $manifestAbs)) {
    if ($chkAutoFetchBase.Checked) {
      Add-Log "Base manifest: will auto-fetch in dynamic mode"
    } else {
      Add-Log "Base manifest: missing"
    }
  } else {
    Add-Log "Base manifest: OK"
  }

  $configAbs = To-Absolute -PathValue $txtConfig.Text
  if (-not (Test-Path $configAbs)) {
    Add-Log "Config path: missing"
  } else {
    Add-Log "Config path: OK"
  }

  if (Get-Command aria2c -ErrorAction SilentlyContinue) {
    Add-Log "aria2c detected"
  } else {
    if ($chkDownloadOnPi.Checked) {
      Add-Log "aria2c not detected on Windows: OK for Pi-side download mode"
    } else {
      Add-Log "aria2c not detected; Windows-side dynamic download mode will fail"
    }
  }

  $baseStatus = if (-not [string]::IsNullOrWhiteSpace($baseAbs) -and (Test-Path $baseAbs)) { "Local base override ready" } else { "Pinned base image will download automatically" }
  $configStatus = if (Test-Path $configAbs) { "config ready" } else { "config missing" }
  $summary = "Administrator: $(if ($isAdmin) { 'ready' } else { 'required' }) | WSL: $(if ($wslReady) { 'ready' } else { 'missing' }) | $baseStatus | $configStatus"
  if ($null -ne $script:developerStatus) {
    $script:developerStatus.Text = $summary
  }
  [System.Windows.Forms.MessageBox]::Show($summary, "Prerequisite check", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})

$btnBuild.Add_Click({
  $baseAbs = To-Absolute -PathValue $txtBase.Text
  $configAbs = To-Absolute -PathValue $txtConfig.Text

  if (-not (Test-Path $configAbs)) {
    Add-Log "Build aborted: config file not found."
    return
  }

  $args = @(
    "-ConfigPath", (Quote-Arg -Value $configAbs),
    "-ResolvedConfigPath", (Quote-Arg -Value (Join-Path $workspaceDirectory "appliance-config.json")),
    "-BaseImageCacheDir", (Quote-Arg -Value (Join-Path $workspaceDirectory "base-image-cache")),
    "-OutputImagePath", (Quote-Arg -Value $txtImagePath.Text),
    "-ManifestPath", (Quote-Arg -Value $txtManifestPath.Text)
  )

  if (-not [string]::IsNullOrWhiteSpace($baseAbs) -and (Test-Path $baseAbs)) {
    $args += @("-BaseImagePath", (Quote-Arg -Value $baseAbs))
    Add-Log "Using advanced local Raspberry Pi OS image override."
  } else {
    Add-Log "Using pinned, verified Raspberry Pi OS Lite image."
  }

  $zimAbs = To-Absolute -PathValue $txtZimDir.Text
  if ([string]::IsNullOrWhiteSpace($zimAbs)) {
    Add-Log "Build aborted: ZIM source directory is required for offline-ready images."
    return
  }
  if (-not (Test-Path $zimAbs)) {
    Add-Log "Build aborted: ZIM source directory not found."
    return
  }
  $args += @("-ZimSourceDir", (Quote-Arg -Value $zimAbs))

  Add-Log "Building appliance image"
  $result = Invoke-PowerShellScript -ScriptPath $buildScript -Arguments $args
  if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
    Add-Log $result.Output
  }

  if ($result.ExitCode -eq 0) {
    Add-Log "Build completed successfully."
  } else {
    Add-Log "Build failed with exit code $($result.ExitCode)."
  }
})

$btnWrite.Add_Click({
  [int]$diskNum = Get-SelectedDiskNumber
  if ($diskNum -lt 0) {
    Add-Log "Write aborted: select an SD card in Step 2."
    return
  }

  $imgAbs = To-Absolute -PathValue $txtImagePath.Text
  $manifestAbs = To-Absolute -PathValue $txtManifestPath.Text
  $configAbs = To-Absolute -PathValue $txtConfig.Text

  if (-not (Test-Path $imgAbs)) {
    Add-Log "Write aborted: image file not found."
    return
  }
  if (-not (Test-Path $manifestAbs)) {
    Add-Log "Write aborted: manifest file not found."
    return
  }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    "This will erase disk #$diskNum. Continue?",
    "Confirm SD Write",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )

  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
    Add-Log "Write cancelled by user."
    return
  }

  $args = @(
    "-DiskNumber", $diskNum,
    "-ConfirmDiskNumber", $diskNum,
    "-ConfigPath", (Quote-Arg -Value $configAbs),
    "-ImagePath", (Quote-Arg -Value $imgAbs),
    "-ManifestPath", (Quote-Arg -Value $manifestAbs),
    "-Force"
  )

  Add-Log "Writing appliance image to disk #$diskNum"
  $result = Invoke-PowerShellScript -ScriptPath $writeScript -Arguments $args
  if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
    Add-Log $result.Output
  }

  if ($result.ExitCode -eq 0) {
    Add-Log "SD write completed successfully."
  } else {
    Add-Log "SD write failed with exit code $($result.ExitCode)."
  }
})

$btnEstimate.Add_Click({
  try {
    $entries = Resolve-EntriesForDynamicRun
    [int]$diskNum = Get-SelectedDiskNumber

    $estimate = Get-PreflightEstimate -Entries $entries -CacheDir $txtCacheDir.Text -BaseImagePath $txtBase.Text -AutoFetch $chkAutoFetchBase.Checked -ReleaseRepo $txtReleaseRepo.Text -DiskNumber $diskNum
    Log-PreflightEstimate -Estimate $estimate
  } catch {
    Add-Log "Estimate failed: $($_.Exception.Message)"
  }
})

$btnDynamic.Add_Click({
  [int]$diskNum = Get-SelectedDiskNumber
  if ($diskNum -lt 0) {
    Add-Log "Dynamic build aborted: select an SD card in Step 2."
    if ($script:normalLaunch) {
      [System.Windows.Forms.MessageBox]::Show("Select an SD card and try again.", $appDisplayName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      $form.Close()
    }
    return
  }

  $configAbs = To-Absolute -PathValue $txtConfig.Text
  if (-not (Test-Path $configAbs)) {
    Add-Log "Dynamic build aborted: config file not found."
    if ($script:normalLaunch) {
      [System.Windows.Forms.MessageBox]::Show("The application configuration is missing. Re-extract the complete release ZIP and try again.", $appDisplayName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
      $form.Close()
    }
    return
  }

  $baseAbs = To-Absolute -PathValue $txtBase.Text

  $entries = $null
  $generatedProfile = ""
  $estimate = $null
  try {
    $entries = Resolve-EntriesForDynamicRun
    $generatedProfile = Write-GeneratedProfileFile -Entries $entries
    Add-Log "Using generated profile: $generatedProfile"

    $estimate = Get-PreflightEstimate -Entries $entries -CacheDir $txtCacheDir.Text -BaseImagePath $txtBase.Text -AutoFetch $false -ReleaseRepo $txtReleaseRepo.Text -DiskNumber $diskNum
    Log-PreflightEstimate -Estimate $estimate
  } catch {
    Add-Log "Dynamic preflight failed: $($_.Exception.Message)"
    if ($script:normalLaunch) {
      [System.Windows.Forms.MessageBox]::Show("The SD card could not be prepared: $($_.Exception.Message)", $appDisplayName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
      $form.Close()
    }
    return
  }

  $requiredText = Format-Bytes -Bytes $estimate.RequiredBytes
  $unknownText = $estimate.UnknownCount
  if ($estimate.Fits -eq $false) {
    Add-Log "Dynamic build aborted: selected SD card is too small."
    [System.Windows.Forms.MessageBox]::Show("The selected SD card is too small. Choose a card with at least $requiredText.", "SD Card Too Small", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    if ($script:normalLaunch) {
      $form.Close()
    }
    return
  }

  try {
    $disk = Get-Disk -Number $diskNum -ErrorAction Stop
    $diskLabel = "$($disk.FriendlyName) - $(Format-Bytes -Bytes $disk.Size) - Disk $diskNum"
  } catch {
    $diskLabel = "Disk $diskNum"
  }

  $contentMode = if ($chkDownloadOnPi.Checked) { "FirstBoot" } else { "Prebuilt" }
  $contentModeText = if ($contentMode -eq "FirstBoot") { "Selected catalogs download automatically on the Pi's first boot with Internet." } else { "Selected catalogs download now and the Pi is ready offline on first boot." }
  $confirmText = "This will erase the selected SD card:`n$diskLabel`n`nEverything currently on this card will be deleted.`n`n$contentModeText`nRequired capacity: $requiredText`nUnknown-size entries: $unknownText`n`nCreate Emergency Web Pi?"

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    $confirmText,
    "Erase and Create Emergency Web Pi",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )

  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
    Add-Log "Dynamic build cancelled by user."
    if ($script:normalLaunch) {
      $form.Close()
    }
    return
  }

  $args = @(
    "-DiskNumber", $diskNum,
    "-ConfirmDiskNumber", $diskNum,
    "-BaseConfigPath", (Quote-Arg -Value $configAbs),
    "-ProfilePath", (Quote-Arg -Value $generatedProfile),
    "-CacheDir", (Quote-Arg -Value $txtCacheDir.Text),
    "-WorkspaceDir", (Quote-Arg -Value $workspaceDirectory),
    "-BaseImageCacheDir", (Quote-Arg -Value (Join-Path $workspaceDirectory "base-image-cache")),
    "-ContentMode", $contentMode
  )

  if ($chkUpstream.Checked) {
    if ([string]::IsNullOrWhiteSpace($txtUpstreamSsid.Text) -or [string]::IsNullOrWhiteSpace($txtUpstreamPassword.Text)) {
      [System.Windows.Forms.MessageBox]::Show("Enter the home Wi-Fi name and password, or clear the home Wi-Fi option.", "Home Wi-Fi", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }
    $args += @("-UpstreamSsid", (Quote-Arg -Value $txtUpstreamSsid.Text), "-UpstreamPassword", (Quote-Arg -Value $txtUpstreamPassword.Text))
  }

  if (-not [string]::IsNullOrWhiteSpace($baseAbs) -and (Test-Path $baseAbs)) {
    $args += @("-BaseImagePath", (Quote-Arg -Value $baseAbs))
    Add-Log "Using advanced local Raspberry Pi OS image override."
  } else {
    Add-Log "Using pinned, verified Raspberry Pi OS Lite image."
  }

  Add-Log "Dynamic mode content installation: $contentMode"

  Add-Log "Running dynamic SD build on disk #$diskNum"
  $progress = $null
  if ($script:normalLaunch) {
    $progress = New-Object System.Windows.Forms.Form
    $progress.Text = $appDisplayName
    $progress.Size = New-Object System.Drawing.Size(520, 180)
    $progress.StartPosition = "CenterScreen"
    $progress.FormBorderStyle = "FixedDialog"
    $progress.ControlBox = $false

    $message = New-Object System.Windows.Forms.Label
    $message.Left = 24
    $message.Top = 28
    $message.Width = 450
    $message.Height = 56
    $message.Text = "Creating your Emergency Web Pi SD card.`r`nKeep this window open. Large downloads can take a while."
    $progress.Controls.Add($message)

    $progress.Show()
    $progress.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
  }

  try {
    $result = Invoke-PowerShellScript -ScriptPath $dynamicScript -Arguments $args
  } finally {
    if ($null -ne $progress) {
      $progress.Close()
      $progress.Dispose()
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
    Add-Log $result.Output
  }

  if ($result.ExitCode -eq 0) {
    Add-Log "Dynamic SD build completed successfully."
    if ($script:normalLaunch) {
      [System.Windows.Forms.MessageBox]::Show("Your SD card is ready. Insert it into the Raspberry Pi and follow the selected content-installation mode.", $appDisplayName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
      $form.Close()
    }
  } else {
    Add-Log "Dynamic SD build failed with exit code $($result.ExitCode)."
    if ($script:normalLaunch) {
      [System.Windows.Forms.MessageBox]::Show("Creating the SD card did not finish. Try again after reviewing the error details in Advanced Settings.", $appDisplayName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
      $form.Close()
    }
  }
})

$btnDisks.Add_Click({
  Refresh-DiskPicker
  Add-Log "SD card list refreshed."
})

$btnArtifacts.Add_Click({
  if (-not (Test-Path $workspaceDirectory)) {
    New-Item -ItemType Directory -Path $workspaceDirectory -Force | Out-Null
  }
  Start-Process explorer.exe $workspaceDirectory
})

$btnAbout.Add_Click({
  $noticePath = Join-Path $repoRoot "docs/THIRD_PARTY_NOTICES.md"
  if (Test-Path $noticePath) {
    Start-Process $noticePath
  } else {
    [System.Windows.Forms.MessageBox]::Show(
      "License notice file not found at docs/THIRD_PARTY_NOTICES.md",
      $appDisplayName,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  }
})

$btnExit.Add_Click({ $form.Close() })

Refresh-ProfilePicker
Load-SelectedPresetItems
Refresh-DiskPicker
Set-AdvancedVisibility -Visible $false

Add-Log "Offline library builder ready"
Add-Log "Repository root: $repoRoot"

$script:normalLaunch = $true
Write-AppLog "Starting end-user wizard as the visible frontend."
Start-EndUserFlow

if (-not $form.IsDisposed -and -not $script:normalLaunch) {
  [void]$form.ShowDialog()
}
