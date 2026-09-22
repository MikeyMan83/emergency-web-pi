Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $repoRoot "scripts/build-appliance-image.ps1"
$writeScript = Join-Path $repoRoot "scripts/create-sd.ps1"

if (-not (Test-Path $buildScript) -or -not (Test-Path $writeScript)) {
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "Pi Kiwix Portable Builder"
$form.Size = New-Object System.Drawing.Size(980, 760)
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
  $tb.Width = 610
  $tb.Text = $DefaultText
  $form.Controls.Add($tb)
  return $tb
}

function Add-BrowseButton {
  param([int]$Top)
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = "Browse"
  $btn.Left = 860
  $btn.Top = $Top - 4
  $btn.Width = 90
  $form.Controls.Add($btn)
  return $btn
}

Add-Label -Text "Base OS Image" -Top $y
$txtBase = Add-TextBox -DefaultText "" -Top $y
$btnBase = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Config JSON" -Top $y
$txtConfig = Add-TextBox -DefaultText "config/appliance.example.json" -Top $y
$btnConfig = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Optional ZIM Source Dir" -Top $y
$txtZimDir = Add-TextBox -DefaultText "" -Top $y
$btnZimDir = Add-BrowseButton -Top $y
$y += 40

Add-Label -Text "Output Image Path" -Top $y
$txtImagePath = Add-TextBox -DefaultText "artifacts/appliance.img" -Top $y
$y += 40

Add-Label -Text "Manifest Path" -Top $y
$txtManifestPath = Add-TextBox -DefaultText "artifacts/appliance.img.manifest.json" -Top $y
$y += 40

Add-Label -Text "Target Disk Number" -Top $y
$txtDisk = Add-TextBox -DefaultText "" -Top $y
$y += 50

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Check Prereqs"
$btnCheck.Left = 20
$btnCheck.Top = $y
$btnCheck.Width = 140
$form.Controls.Add($btnCheck)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = "Build Image"
$btnBuild.Left = 180
$btnBuild.Top = $y
$btnBuild.Width = 140
$form.Controls.Add($btnBuild)

$btnWrite = New-Object System.Windows.Forms.Button
$btnWrite.Text = "Write SD"
$btnWrite.Left = 340
$btnWrite.Top = $y
$btnWrite.Width = 140
$form.Controls.Add($btnWrite)

$btnDisks = New-Object System.Windows.Forms.Button
$btnDisks.Text = "List Disks"
$btnDisks.Left = 500
$btnDisks.Top = $y
$btnDisks.Width = 140
$form.Controls.Add($btnDisks)

$btnArtifacts = New-Object System.Windows.Forms.Button
$btnArtifacts.Text = "Open Artifacts"
$btnArtifacts.Left = 660
$btnArtifacts.Top = $y
$btnArtifacts.Width = 140
$form.Controls.Add($btnArtifacts)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Exit"
$btnExit.Left = 820
$btnExit.Top = $y
$btnExit.Width = 130
$form.Controls.Add($btnExit)

$y += 50

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Left = 20
$txtLog.Top = $y
$txtLog.Width = 930
$txtLog.Height = 600 - $y + 70
$form.Controls.Add($txtLog)

function Add-Log {
  param([string]$Text)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $txtLog.AppendText("[$stamp] $Text`r`n")
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

$btnBase.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Image Files (*.img;*.xz;*.zip)|*.img;*.xz;*.zip|All Files (*.*)|*.*"
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtBase.Text = $dlg.FileName
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

$btnCheck.Add_Click({
  Add-Log "Checking prerequisites"

  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Add-Log "PowerShell elevation: OK"
  } else {
    Add-Log "PowerShell elevation: REQUIRED for Write SD"
  }

  try {
    $wslVersion = & wsl --version 2>$null
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
    Add-Log "Base image: missing"
  } else {
    Add-Log "Base image: OK"
  }

  $configAbs = To-Absolute -PathValue $txtConfig.Text
  if (-not (Test-Path $configAbs)) {
    Add-Log "Config path: missing"
  } else {
    Add-Log "Config path: OK"
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
  if (-not [string]::IsNullOrWhiteSpace($zimAbs)) {
    if (-not (Test-Path $zimAbs)) {
      Add-Log "Build aborted: ZIM source directory not found."
      return
    }
    $args += @("-ZimSourceDir", (Quote-Arg -Value $zimAbs))
  }

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

Add-Log "Pi Kiwix Portable ready"
Add-Log "Repository root: $repoRoot"

[void]$form.ShowDialog()
