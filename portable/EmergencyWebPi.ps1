Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$appDisplayName = "Emergency Web Pi"

trap {
  [System.Windows.Forms.MessageBox]::Show(
    $_.Exception.Message,
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
  $checked = ($candidateDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join "`n"
  [System.Windows.Forms.MessageBox]::Show(
    "Unable to locate bundled scripts.`n`nExtract the full release ZIP first, then run EmergencyWebPi.exe from the extracted folder.`n`nChecked paths:`n$checked",
    $appDisplayName,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

$buildScript = Join-Path $repoRoot "scripts/build-appliance-image.ps1"
$writeScript = Join-Path $repoRoot "scripts/create-sd.ps1"
$dynamicScript = Join-Path $repoRoot "scripts/create-sd-dynamic.ps1"

if (-not (Test-Path $buildScript) -or -not (Test-Path $writeScript) -or -not (Test-Path $dynamicScript)) {
  [System.Windows.Forms.MessageBox]::Show(
    "Required scripts are missing. Ensure this portable folder is inside the repository root.",
    $appDisplayName,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

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

function Get-RemoteContentLength {
  param([Parameter(Mandatory = $true)][string]$Url)

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
    $lengthHeader = $response.Headers["Content-Length"]
    if ($lengthHeader) {
      return [int64]$lengthHeader
    }
  } catch {
    return $null
  }

  return $null
}

function Get-LatestReleaseBaseImageSize {
  param([Parameter(Mandatory = $true)][string]$Repo)

  try {
    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "pi-kiwix-portable" }
    $imageAsset = $release.assets |
      Where-Object { $_.name -imatch "(appliance|base).+\.img$" } |
      Select-Object -First 1

    if (-not $imageAsset) {
      $imageAsset = $release.assets |
        Where-Object { $_.name -imatch "\.img$" } |
        Select-Object -First 1
    }

    if ($imageAsset -and $imageAsset.size) {
      return [int64]$imageAsset.size
    }
  } catch {
    return $null
  }

  return $null
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

  $resolvedCache = To-Absolute -PathValue $CacheDir
  if (-not (Test-Path $resolvedCache)) {
    New-Item -ItemType Directory -Path $resolvedCache | Out-Null
  }

  foreach ($url in $Entries) {
    $name = Resolve-ZimFileName -Url $url
    $cachePath = Join-Path $resolvedCache $name

    if (Test-Path $cachePath -PathType Leaf) {
      $size = (Get-Item $cachePath).Length
      if ($size -gt 0) {
        $knownContentBytes += [int64]$size
        $cachedCount += 1
        continue
      }
    }

    $remoteSize = Get-RemoteContentLength -Url $url
    if ($null -ne $remoteSize -and $remoteSize -gt 0) {
      $knownContentBytes += [int64]$remoteSize
      $downloadBytes += [int64]$remoteSize
    } else {
      $unknownCount += 1
    }
  }

  $baseBytes = [int64]0
  $resolvedBase = To-Absolute -PathValue $BaseImagePath
  if (-not [string]::IsNullOrWhiteSpace($resolvedBase) -and (Test-Path $resolvedBase -PathType Leaf)) {
    $baseBytes = (Get-Item $resolvedBase).Length
  } else {
    $baseBytes = [int64](Get-PinnedBaseImageInfo).installedSizeBytes
  }

  # 5 percent padding for filesystem metadata and safety margin.
  $requiredBytes = [int64][Math]::Ceiling(($baseBytes + $knownContentBytes) * 1.05)

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

  $baseBytes = [int64](Get-PinnedBaseImageInfo).installedSizeBytes
  return [int64][Math]::Ceiling(($baseBytes + $contentBytes + 1GB) * 1.05)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $appDisplayName
$form.Size = New-Object System.Drawing.Size(1080, 920)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

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
$txtManifestPath = Add-TextBox -DefaultText "artifacts/appliance.img.manifest.json" -Top $y
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
$txtImagePath = Add-TextBox -DefaultText "artifacts/appliance.img" -Top $y
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
$lstProfileItems.CheckOnClick = $true
$form.Controls.Add($lstProfileItems)
$y += 140

$chkUsePicker = New-Object System.Windows.Forms.CheckBox
$chkUsePicker.Text = "Use checked profile items for dynamic build"
$chkUsePicker.Left = 240
$chkUsePicker.Top = $y
$chkUsePicker.Width = 330
$chkUsePicker.Checked = $true
$form.Controls.Add($chkUsePicker)
$y += 30

$lblCacheDir = Add-Label -Text "Dynamic Cache Dir" -Top $y
$txtCacheDir = Add-TextBox -DefaultText "artifacts/zim-cache" -Top $y
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
$btnArtifacts.Text = "Open Artifacts"
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

# Default to first-boot content installation; fully prebuilt cards remain available in the wizard.
$chkDownloadOnPi.Checked = $true

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
      [void]$lstProfileItems.Items.Add($item, $true)
    }

    $txtProfilePath.Text = [string]$cmbProfiles.SelectedItem
    Add-Log "Loaded $($items.Count) profile item(s) from $($cmbProfiles.SelectedItem)."
  } catch {
    Add-Log "Failed to load preset items: $($_.Exception.Message)"
  }
}

function Resolve-EntriesForDynamicRun {
  if ($chkUsePicker.Checked -and $lstProfileItems.Items.Count -gt 0) {
    $selected = @()
    for ($i = 0; $i -lt $lstProfileItems.Items.Count; $i++) {
      if ($lstProfileItems.GetItemChecked($i)) {
        $selected += [string]$lstProfileItems.Items[$i]
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

  $generatedDir = Join-Path (Join-Path $repoRoot "artifacts") "generated-profiles"
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
  $all = Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem }
  $preferred = $all | Where-Object { $_.BusType -in @("USB", "SD") }
  if ($preferred.Count -gt 0) {
    return $preferred
  }
  return $all
}

function Refresh-DiskPicker {
  $cmbDisks.Items.Clear()
  try {
    $disks = Get-SelectableDisks
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
    [Parameter(Mandatory = $true)]$Disks
  )

  $wizard = New-Object System.Windows.Forms.Form
  $wizard.Text = "Emergency Web Pi Wizard"
  $wizard.Size = New-Object System.Drawing.Size(900, 760)
  $wizard.StartPosition = "CenterParent"
  $wizard.FormBorderStyle = "FixedDialog"
  $wizard.MaximizeBox = $false
  $wizard.MinimizeBox = $false
  $wizard.Font = $font

  $wy = 16

  $lblIntro = New-Object System.Windows.Forms.Label
  $lblIntro.Left = 16
  $lblIntro.Top = $wy
  $lblIntro.Width = 850
  $lblIntro.Height = 44
  $lblIntro.Text = "Choose what you want available offline, how to install it, and which SD card to erase."
  $wizard.Controls.Add($lblIntro)
  $wy += 50

  $lblBase = New-Object System.Windows.Forms.Label
  $lblBase.Left = 16
  $lblBase.Top = $wy
  $lblBase.Width = 850
  $baseInfo = Get-PinnedBaseImageInfo
  $lblBase.Text = "Base system: $($baseInfo.name) ($($baseInfo.architecture), $($baseInfo.releaseDate)) - automatically downloaded and SHA-256 verified"
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
  $lblProfileInfo.Width = 660
  $lblProfileInfo.Height = 34
  $wizard.Controls.Add($lblProfileInfo)
  $wy += 40

  $lblItems = New-Object System.Windows.Forms.Label
  $lblItems.Left = 16
  $lblItems.Top = $wy
  $lblItems.Width = 180
  $lblItems.Text = "Fine-tune libraries"
  $wizard.Controls.Add($lblItems)

  $lstWizardItems = New-Object System.Windows.Forms.CheckedListBox
  $lstWizardItems.Left = 210
  $lstWizardItems.Top = $wy
  $lstWizardItems.Width = 660
  $lstWizardItems.Height = 210
  $lstWizardItems.CheckOnClick = $true
  $lstWizardItems.DisplayMember = "Display"
  $wizard.Controls.Add($lstWizardItems)
  $wy += 220

  $btnAll = New-Object System.Windows.Forms.Button
  $btnAll.Text = "Select All"
  $btnAll.Left = 210
  $btnAll.Top = $wy
  $btnAll.Width = 100
  $wizard.Controls.Add($btnAll)

  $btnNone = New-Object System.Windows.Forms.Button
  $btnNone.Text = "Select None"
  $btnNone.Left = 320
  $btnNone.Top = $wy
  $btnNone.Width = 100
  $wizard.Controls.Add($btnNone)
  $wy += 36

  $lblSelection = New-Object System.Windows.Forms.Label
  $lblSelection.Left = 430
  $lblSelection.Top = $wy - 32
  $lblSelection.Width = 440
  $wizard.Controls.Add($lblSelection)

  $lblItemInfo = New-Object System.Windows.Forms.Label
  $lblItemInfo.Left = 210
  $lblItemInfo.Top = $wy - 2
  $lblItemInfo.Width = 540
  $lblItemInfo.Height = 34
  $wizard.Controls.Add($lblItemInfo)

  $btnLearnMore = New-Object System.Windows.Forms.Button
  $btnLearnMore.Text = "Learn More"
  $btnLearnMore.Left = 760
  $btnLearnMore.Top = $wy - 4
  $btnLearnMore.Width = 110
  $btnLearnMore.Enabled = $false
  $wizard.Controls.Add($btnLearnMore)
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
  $cmbWizardDisk.Width = 660
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

  $optFirstBoot = New-Object System.Windows.Forms.RadioButton
  $optFirstBoot.Left = 210
  $optFirstBoot.Top = $wy
  $optFirstBoot.Width = 660
  $optFirstBoot.Checked = $true
  $optFirstBoot.Text = "Recommended: download selected content on first boot (Internet required once)"
  $wizard.Controls.Add($optFirstBoot)
  $wy += 24

  $optPrebuilt = New-Object System.Windows.Forms.RadioButton
  $optPrebuilt.Left = 210
  $optPrebuilt.Top = $wy
  $optPrebuilt.Width = 660
  $optPrebuilt.Text = "Fully prebuild: download content now for an offline-ready first boot"
  $wizard.Controls.Add($optPrebuilt)
  $wy += 38

  $btnCancelWizard = New-Object System.Windows.Forms.Button
  $btnCancelWizard.Text = "Cancel"
  $btnCancelWizard.Left = 670
  $btnCancelWizard.Top = $wy
  $btnCancelWizard.Width = 100
  $wizard.Controls.Add($btnCancelWizard)

  $btnStartWizard = New-Object System.Windows.Forms.Button
  $btnStartWizard.Text = "Estimate + Build"
  $btnStartWizard.Left = 780
  $btnStartWizard.Top = $wy
  $btnStartWizard.Width = 100
  $wizard.Controls.Add($btnStartWizard)

  $result = $null

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
        [void]$lstWizardItems.Items.Add($item, $true)
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
    foreach ($checkedIndex in $lstWizardItems.CheckedIndices) {
      $item = $lstWizardItems.Items[$checkedIndex]
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
    $wizard.BeginInvoke([System.Action]$updateSelection) | Out-Null
  })
  $lstWizardItems.Add_SelectedIndexChanged({
    if ($lstWizardItems.SelectedItem -ne $null) {
      $item = $lstWizardItems.SelectedItem
      $lblItemInfo.Text = $item.Description
      $btnLearnMore.Enabled = -not [string]::IsNullOrWhiteSpace($item.LearnMoreUrl)
    }
  })
  $cmbWizardDisk.Add_SelectedIndexChanged({ & $updateSelection })
  $btnLearnMore.Add_Click({
    if ($lstWizardItems.SelectedItem -ne $null) {
      Start-Process $lstWizardItems.SelectedItem.LearnMoreUrl
    }
  })
  & $updateSelection

  $btnAll.Add_Click({
    for ($i = 0; $i -lt $lstWizardItems.Items.Count; $i++) {
      $lstWizardItems.SetItemChecked($i, $true)
    }
  })

  $btnNone.Add_Click({
    for ($i = 0; $i -lt $lstWizardItems.Items.Count; $i++) {
      $lstWizardItems.SetItemChecked($i, $false)
    }
  })

  $btnCancelWizard.Add_Click({
    $wizard.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $wizard.Close()
  })

  $btnStartWizard.Add_Click({
    if ($cmbWizardProfile.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("Select a catalog preset.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    if ($cmbWizardDisk.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show("Select a target disk.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    $entries = @()
    for ($i = 0; $i -lt $lstWizardItems.Items.Count; $i++) {
      if ($lstWizardItems.GetItemChecked($i)) {
        $entries += [string]$lstWizardItems.Items[$i].Url
      }
    }

    if ($entries.Count -eq 0) {
      [System.Windows.Forms.MessageBox]::Show("Select at least one catalog item.", "Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    $selectedItems = @()
    foreach ($checkedIndex in $lstWizardItems.CheckedIndices) {
      $selectedItems += $lstWizardItems.Items[$checkedIndex]
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

  $dialogResult = $wizard.ShowDialog($form)
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
})

$btnDiskRefreshInline.Add_Click({
  Refresh-DiskPicker
  Add-Log "SD card list refreshed."
})

$btnToggleAdvanced.Add_Click({
  Set-AdvancedVisibility -Visible (-not $showAdvanced)
})

$btnWizard.Add_Click({
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
      Add-Log "Wizard aborted: no writable target disks found."
      return
    }

    $defaultProfile = if ($cmbProfiles.SelectedItem) { [string]$cmbProfiles.SelectedItem } else { $profilePaths[0] }
    $selection = Show-EndUserWizard -ProfilePaths $profilePaths -DefaultProfile $defaultProfile -Disks $disks
    if ($null -eq $selection) {
      Add-Log "Wizard cancelled."
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
  }
})

$btnLoadProfile.Add_Click({
  Load-SelectedPresetItems
})

$btnCheck.Add_Click({
  Add-Log "Checking prerequisites"

  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Add-Log "PowerShell elevation: OK"
  } else {
    Add-Log "PowerShell elevation: REQUIRED for SD write"
  }

  try {
    $null = & wsl --version 2>$null
    if ($LASTEXITCODE -eq 0) {
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
})

$btnBuild.Add_Click({
  $baseAbs = To-Absolute -PathValue $txtBase.Text
  $configAbs = To-Absolute -PathValue $txtConfig.Text

  if ([string]::IsNullOrWhiteSpace($baseAbs) -or -not (Test-Path $baseAbs)) {
    Add-Log "Build aborted: base image not found."
    return
  }

  if (-not (Test-Path $configAbs)) {
    Add-Log "Build aborted: config file not found."
    return
  }

  $args = @(
    "-BaseImagePath", (Quote-Arg -Value $baseAbs),
    "-ConfigPath", (Quote-Arg -Value $configAbs),
    "-OutputImagePath", (Quote-Arg -Value $txtImagePath.Text),
    "-ManifestPath", (Quote-Arg -Value $txtManifestPath.Text)
  )

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
    return
  }

  $configAbs = To-Absolute -PathValue $txtConfig.Text
  if (-not (Test-Path $configAbs)) {
    Add-Log "Dynamic build aborted: config file not found."
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
    return
  }

  $requiredText = Format-Bytes -Bytes $estimate.RequiredBytes
  $unknownText = $estimate.UnknownCount
  if ($estimate.Fits -eq $false) {
    Add-Log "Dynamic build aborted: selected SD card is too small."
    [System.Windows.Forms.MessageBox]::Show("The selected SD card is too small. Choose a card with at least $requiredText.", "SD Card Too Small", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
    return
  }

  $args = @(
    "-DiskNumber", $diskNum,
    "-ConfirmDiskNumber", $diskNum,
    "-BaseConfigPath", (Quote-Arg -Value $configAbs),
    "-ProfilePath", (Quote-Arg -Value $generatedProfile),
    "-CacheDir", (Quote-Arg -Value $txtCacheDir.Text),
    "-ContentMode", $contentMode
  )

  if (-not [string]::IsNullOrWhiteSpace($baseAbs) -and (Test-Path $baseAbs)) {
    $args += @("-BaseImagePath", (Quote-Arg -Value $baseAbs))
    Add-Log "Using advanced local Raspberry Pi OS image override."
  } else {
    Add-Log "Using pinned, verified Raspberry Pi OS Lite image."
  }

  Add-Log "Dynamic mode content installation: $contentMode"

  Add-Log "Running dynamic SD build on disk #$diskNum"
  $result = Invoke-PowerShellScript -ScriptPath $dynamicScript -Arguments $args
  if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
    Add-Log $result.Output
  }

  if ($result.ExitCode -eq 0) {
    Add-Log "Dynamic SD build completed successfully."
  } else {
    Add-Log "Dynamic SD build failed with exit code $($result.ExitCode)."
  }
})

$btnDisks.Add_Click({
  Refresh-DiskPicker
  Add-Log "SD card list refreshed."
})

$btnArtifacts.Add_Click({
  $artifacts = Join-Path $repoRoot "artifacts"
  if (-not (Test-Path $artifacts)) {
    New-Item -ItemType Directory -Path $artifacts | Out-Null
  }
  Start-Process explorer.exe $artifacts
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

[void]$form.ShowDialog()
