Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $repoRoot "scripts/build-appliance-image.ps1"
$writeScript = Join-Path $repoRoot "scripts/create-sd.ps1"
$dynamicScript = Join-Path $repoRoot "scripts/create-sd-dynamic.ps1"

if (-not (Test-Path $buildScript) -or -not (Test-Path $writeScript) -or -not (Test-Path $dynamicScript)) {
  [System.Windows.Forms.MessageBox]::Show(
    "Required scripts are missing. Ensure this portable folder is inside the repository root.",
    "Pi Kiwix Portable",
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

function Resolve-ZimFileName {
  param([Parameter(Mandatory = $true)][string]$Url)

  $name = [System.IO.Path]::GetFileName($Url)
  if ($name.EndsWith(".torrent", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $name.Substring(0, $name.Length - 8)
  }

  return $name
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
  } elseif ($AutoFetch) {
    $latestBytes = Get-LatestReleaseBaseImageSize -Repo $ReleaseRepo
    if ($latestBytes) {
      $baseBytes = $latestBytes
    }
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "Pi Kiwix Portable Builder"
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

Add-Label -Text "Base Appliance Image" -Top $y
$txtBase = Add-TextBox -DefaultText "artifacts/appliance.img" -Top $y
$btnBase = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Manifest Path" -Top $y
$txtManifestPath = Add-TextBox -DefaultText "artifacts/appliance.img.manifest.json" -Top $y
$btnManifest = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Config JSON" -Top $y
$txtConfig = Add-TextBox -DefaultText "config/appliance.example.json" -Top $y
$btnConfig = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "ZIM Source Dir" -Top $y
$txtZimDir = Add-TextBox -DefaultText "" -Top $y
$btnZimDir = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Output Image Path" -Top $y
$txtImagePath = Add-TextBox -DefaultText "artifacts/appliance.img" -Top $y
$y += 40

Add-Label -Text "Dynamic Profile List (file)" -Top $y
$txtProfilePath = Add-TextBox -DefaultText "profiles/medical-survival-zimlist.txt" -Top $y
$btnProfile = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Profile Preset" -Top $y
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

Add-Label -Text "Profile Items (checked = include)" -Top $y
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

Add-Label -Text "Dynamic Cache Dir" -Top $y
$txtCacheDir = Add-TextBox -DefaultText "artifacts/zim-cache" -Top $y
$y += 40

Add-Label -Text "Target Disk Number" -Top $y
$txtDisk = Add-TextBox -DefaultText "" -Top $y
$y += 40

$chkAutoFetchBase = New-Object System.Windows.Forms.CheckBox
$chkAutoFetchBase.Text = "Dynamic mode: auto-fetch latest base image + manifest from latest GitHub release"
$chkAutoFetchBase.Left = 240
$chkAutoFetchBase.Top = $y
$chkAutoFetchBase.Width = 620
$chkAutoFetchBase.Checked = $false
$form.Controls.Add($chkAutoFetchBase)

$y += 30

Add-Label -Text "Release Repo" -Top $y
$txtReleaseRepo = Add-TextBox -DefaultText "MikeyMan83/pi-kiwix-survival" -Top $y
$y += 40

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Check Prereqs"
$btnCheck.Left = 20
$btnCheck.Top = $y
$btnCheck.Width = 120
$form.Controls.Add($btnCheck)

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
$btnDynamic.Text = "Dynamic SD"
$btnDynamic.Left = 540
$btnDynamic.Top = $y
$btnDynamic.Width = 120
$form.Controls.Add($btnDynamic)

$btnDisks = New-Object System.Windows.Forms.Button
$btnDisks.Text = "List Disks"
$btnDisks.Left = 670
$btnDisks.Top = $y
$btnDisks.Width = 120
$form.Controls.Add($btnDisks)

$btnArtifacts = New-Object System.Windows.Forms.Button
$btnArtifacts.Text = "Open Artifacts"
$btnArtifacts.Left = 800
$btnArtifacts.Top = $y
$btnArtifacts.Width = 120
$form.Controls.Add($btnArtifacts)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Exit"
$btnExit.Left = 930
$btnExit.Top = $y
$btnExit.Width = 110
$form.Controls.Add($btnExit)

$y += 50

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
    $cmbProfiles.SelectedIndex = 0
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
    Add-Log "aria2c not detected; dynamic download mode will fail"
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
  if ([string]::IsNullOrWhiteSpace($txtDisk.Text)) {
    Add-Log "Write aborted: enter a disk number."
    return
  }

  [int]$diskNum = -1
  if (-not [int]::TryParse($txtDisk.Text, [ref]$diskNum)) {
    Add-Log "Write aborted: disk number must be an integer."
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
    [int]$diskNum = -1
    if ([string]::IsNullOrWhiteSpace($txtDisk.Text) -or -not [int]::TryParse($txtDisk.Text, [ref]$diskNum)) {
      $diskNum = -1
    }

    $estimate = Get-PreflightEstimate -Entries $entries -CacheDir $txtCacheDir.Text -BaseImagePath $txtBase.Text -AutoFetch $chkAutoFetchBase.Checked -ReleaseRepo $txtReleaseRepo.Text -DiskNumber $diskNum
    Log-PreflightEstimate -Estimate $estimate
  } catch {
    Add-Log "Estimate failed: $($_.Exception.Message)"
  }
})

$btnDynamic.Add_Click({
  if ([string]::IsNullOrWhiteSpace($txtDisk.Text)) {
    Add-Log "Dynamic build aborted: enter a disk number."
    return
  }

  [int]$diskNum = -1
  if (-not [int]::TryParse($txtDisk.Text, [ref]$diskNum)) {
    Add-Log "Dynamic build aborted: disk number must be an integer."
    return
  }

  $configAbs = To-Absolute -PathValue $txtConfig.Text
  if (-not (Test-Path $configAbs)) {
    Add-Log "Dynamic build aborted: config file not found."
    return
  }

  $baseAbs = To-Absolute -PathValue $txtBase.Text
  $manifestAbs = To-Absolute -PathValue $txtManifestPath.Text

  if (-not $chkAutoFetchBase.Checked) {
    if (-not (Test-Path $baseAbs)) {
      Add-Log "Dynamic build aborted: base image not found."
      return
    }
    if (-not (Test-Path $manifestAbs)) {
      Add-Log "Dynamic build aborted: base manifest not found."
      return
    }
  }

  $entries = $null
  $generatedProfile = ""
  $estimate = $null
  try {
    $entries = Resolve-EntriesForDynamicRun
    $generatedProfile = Write-GeneratedProfileFile -Entries $entries
    Add-Log "Using generated profile: $generatedProfile"

    $estimate = Get-PreflightEstimate -Entries $entries -CacheDir $txtCacheDir.Text -BaseImagePath $txtBase.Text -AutoFetch $chkAutoFetchBase.Checked -ReleaseRepo $txtReleaseRepo.Text -DiskNumber $diskNum
    Log-PreflightEstimate -Estimate $estimate
  } catch {
    Add-Log "Dynamic preflight failed: $($_.Exception.Message)"
    return
  }

  $requiredText = Format-Bytes -Bytes $estimate.RequiredBytes
  $unknownText = $estimate.UnknownCount
  $confirmText = "This will erase disk #$diskNum and repopulate content.`n`nEstimated minimum SD size: $requiredText`nUnknown-size entries: $unknownText`n`nContinue?"

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    $confirmText,
    "Confirm Dynamic SD Build",
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
    "-CacheDir", (Quote-Arg -Value $txtCacheDir.Text)
  )

  if ($chkAutoFetchBase.Checked) {
    $args += @("-FetchLatestBase", "-ReleaseRepo", (Quote-Arg -Value $txtReleaseRepo.Text))
    Add-Log "Dynamic mode will auto-fetch latest base artifacts from $($txtReleaseRepo.Text)."
  } else {
    $args += @("-BaseImagePath", (Quote-Arg -Value $baseAbs), "-BaseManifestPath", (Quote-Arg -Value $manifestAbs))
  }

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
  Add-Log "Listing disks"
  try {
    $output = Get-Disk | Select-Object Number, FriendlyName, Size, BusType, IsBoot, IsSystem | Format-Table -AutoSize | Out-String
    Add-Log $output.Trim()
  } catch {
    Add-Log "Failed to list disks: $($_.Exception.Message)"
  }
})

$btnArtifacts.Add_Click({
  $artifacts = Join-Path $repoRoot "artifacts"
  if (-not (Test-Path $artifacts)) {
    New-Item -ItemType Directory -Path $artifacts | Out-Null
  }
  Start-Process explorer.exe $artifacts
})

$btnExit.Add_Click({ $form.Close() })

Refresh-ProfilePicker
Load-SelectedPresetItems

Add-Log "Pi Kiwix Portable ready"
Add-Log "Repository root: $repoRoot"

[void]$form.ShowDialog()
