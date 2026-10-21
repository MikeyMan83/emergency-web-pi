#Requires -Version 5.1
<#
.SYNOPSIS
    Emergency Web Pi - one-button SD card creator (WPF).
.DESCRIPTION
    Presents a guided creator that prepares a Raspberry Pi SD card with an
    offline Kiwix library. All imaging, downloading and writing is performed
    by the existing PowerShell appliance engine; this file is presentation
    and orchestration only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:logTargets = New-Object System.Collections.Generic.List[object]
$script:buildJob = $null
$script:buildCancelled = $false
$script:prebuiltFlow = $false
$script:baseImageRetryDone = $false
$script:logFile = $null

function Write-AppLog {
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp] $Message"
    foreach ($target in $script:logTargets) {
        try {
            $target.Dispatcher.Invoke([action] {
                $target.AppendText($line + [Environment]::NewLine)
                $target.ScrollToEnd()
                if ($target.Text.Length -gt 120000) {
                    $target.Text = $target.Text.Substring($target.Text.Length - 100000)
                    $target.ScrollToEnd()
                }
            }, [System.Threading.DispatcherPriority]::Background)
        } catch { }
    }
    if (-not $script:logFile) {
        $logDir = Join-Path $script:repoRoot 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:logFile = Join-Path $logDir ("startup-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
    }
    # Another process (the release smoke test, antivirus) can briefly hold the
    # log file with a share mode that makes this append fail; retry so no line
    # is silently lost.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Add-Content -Path $script:logFile -Value $line -Encoding UTF8 -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
}

function Add-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-AppLog $Message
}

function Install-UnhandledExceptionHandlers {
    [System.AppDomain]::CurrentDomain.add_UnhandledException({ param($sender, $eventArgs)
        try { Write-AppLog ("Unhandled error: " + $eventArgs.ExceptionObject.ToString()) } catch { }
    })
    if ($script:window -and $script:window.Dispatcher) {
        $script:window.Dispatcher.add_UnhandledException({ param($sender, $eventArgs)
            try {
                Write-AppLog ("UI thread exception: " + $eventArgs.Exception.ToString())
                $eventArgs.Handled = $true
            } catch { }
        })
    }
}

$script:repoRoot = ''
foreach ($candidate in @((Split-Path -Parent $PSScriptRoot), $PSScriptRoot, (Get-Location).Path)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path (Join-Path $candidate 'scripts\create-sd-prebuilt.ps1'))) {
        $script:repoRoot = [System.IO.Path]::GetFullPath($candidate)
        break
    }
}
if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
$logDirectory = Join-Path $script:repoRoot 'logs'
if (-not (Test-Path $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
Get-ChildItem -Path $logDirectory -Filter 'startup-*.log' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 10 |
    Remove-Item -Force -ErrorAction SilentlyContinue
$script:uiDirectory = Join-Path $PSScriptRoot 'ui'
$script:localDataDirectory = Join-Path $env:LOCALAPPDATA 'EmergencyWebPi'
$script:workspaceDirectory = Join-Path $script:localDataDirectory 'workspace'
$script:cacheDirectory = Join-Path $script:localDataDirectory 'cache'
foreach ($dir in @($script:localDataDirectory, $script:workspaceDirectory, $script:cacheDirectory)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Add-Type -AssemblyName System.Xaml -ErrorAction Stop
    Write-AppLog 'WPF assemblies loaded.'
} catch {
    [System.Windows.MessageBox]::Show(
        'Emergency Web Pi needs the Windows desktop components (WPF) that ship with Windows 10 and 11. Please run this application on a normal Windows desktop installation.',
        'Emergency Web Pi', 'OK', 'Error') | Out-Null
    exit 1
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-AppLog 'Not elevated; requesting elevation via UAC.'
        $relaunchArgs = ('-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        try {
            Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunchArgs -Verb RunAs -WindowStyle Hidden | Out-Null
            exit 0
        } catch {
            Write-AppLog ('Elevation was declined or failed: ' + $_.Exception.Message)
        }
    } else {
        Write-AppLog 'Not elevated and no script path available for relaunch.'
    }
    try {
        [System.Windows.MessageBox]::Show('Emergency Web Pi needs administrator permission to write the SD card. Start EmergencyWebPi.exe again and click Yes when Windows asks for permission.', 'Emergency Web Pi', 'OK', 'Warning') | Out-Null
    } catch { }
    exit 1
}
Write-AppLog 'Running elevated.'

if ($env:TEMP -and $PSScriptRoot.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    Write-AppLog 'Refusing to run from a temporary extraction path.'
    [System.Windows.MessageBox]::Show(
        'Please extract the Emergency Web Pi folder to a permanent location (for example Documents) before running it. Windows sometimes unpacks ZIP files into a temporary folder.',
        'Emergency Web Pi', 'OK', 'Warning') | Out-Null
    exit 1
}

Write-AppLog 'Resolving extracted bundle location.'
$versionFile = Join-Path $script:repoRoot 'docs\VERSION'
if (Test-Path $versionFile) {
    $script:appVersion = (Get-Content $versionFile -Raw).Trim()
} else {
    $script:appVersion = 'dev'
}

$requiredScripts = @(
    'scripts\create-sd-prebuilt.ps1',
    'scripts\create-sd-dynamic.ps1',
    'scripts\build-appliance-image.ps1'
)
$missingScripts = @($requiredScripts | Where-Object { -not (Test-Path (Join-Path $script:repoRoot $_)) })
if ($missingScripts.Count -gt 0) {
    Write-AppLog ('Required builder scripts found: missing ' + ($missingScripts -join ', '))
    [System.Windows.MessageBox]::Show(
        'The Emergency Web Pi bundle is incomplete. Please extract the full ZIP again.',
        'Emergency Web Pi', 'OK', 'Error') | Out-Null
    exit 1
}
Write-AppLog 'Required builder scripts found.'
$script:prebuiltScript = Join-Path $script:repoRoot 'scripts\create-sd-prebuilt.ps1'
$script:dynamicScript = Join-Path $script:repoRoot 'scripts\create-sd-dynamic.ps1'
$script:buildImageScript = Join-Path $script:repoRoot 'scripts\build-appliance-image.ps1'

function Get-BundledAria2Directory {
    $candidates = @(
        (Join-Path $script:repoRoot 'tools\aria2'),
        (Join-Path $PSScriptRoot 'tools\aria2')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path (Join-Path $candidate 'aria2c.exe'))) { return $candidate }
    }
    return $null
}

$aria2Dir = Get-BundledAria2Directory
if ($aria2Dir) {
    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $aria2Dir })) {
        $env:PATH = $aria2Dir + ';' + $env:PATH
    }
    Write-AppLog ('Bundled aria2 found at ' + $aria2Dir)
} else {
    Write-AppLog 'Bundled aria2 not found; downloads will use the system fallback.'
}

. (Join-Path $PSScriptRoot 'EmergencyWebPi-Core.ps1')

function To-Absolute {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $script:repoRoot $Path)
}

function Read-XamlWindow {
    param([Parameter(Mandatory)][string]$RelativePath)
    $xamlPath = Join-Path $script:uiDirectory $RelativePath
    $xaml = Get-Content $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlTextReader(New-Object System.IO.StringReader($xaml))
    try {
        return [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
}

function New-MessageDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info',
        [switch]$ShowCancel
    )
    $accent = '#0F6B9D'
    if ($Kind -eq 'Warning') { $accent = '#B45309' }
    if ($Kind -eq 'Error') { $accent = '#B3261E' }
    $escapedTitle = [System.Security.SecurityElement]::Escape($Title)
    $escapedMessage = [System.Security.SecurityElement]::Escape($Message)
    $cancelButton = ''
    if ($ShowCancel) {
        $cancelButton = '<Button x:Name="DlgCancel" Content="Cancel" Style="{StaticResource SecondaryButton}" Margin="0,0,8,0" IsCancel="True"/>'
    }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$escapedTitle" Height="240" Width="460"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#FFFFFF" FontFamily="Segoe UI" FontSize="14">
    <Window.Resources>
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="$accent"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="MinWidth" Value="96"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Opacity" Value="0.8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="White"/>
            <Setter Property="Foreground" Value="#1F2933"/>
            <Setter Property="BorderBrush" Value="#C9D2DC"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="MinWidth" Value="96"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#F4F6F9"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border Padding="24">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Width="4" Height="28" CornerRadius="2" Background="$accent" HorizontalAlignment="Left" Margin="0,0,0,12"/>
            <TextBlock Grid.Row="0" Text="$escapedTitle" FontSize="18" FontWeight="SemiBold" Foreground="#1F2933" Margin="12,0,0,12" VerticalAlignment="Center"/>
            <TextBlock Grid.Row="1" Text="$escapedMessage" TextWrapping="Wrap" Foreground="#3E4C59" VerticalAlignment="Top"/>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                $cancelButton
                <Button x:Name="DlgOk" Content="OK" Style="{StaticResource PrimaryButton}" IsDefault="True"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlTextReader(New-Object System.IO.StringReader($xaml))
    try {
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
    $okButton = $dialog.FindName('DlgOk')
    $script:activeDialog = $dialog
    $okButton.Add_Click({ $script:activeDialog.Tag = 'OK'; $script:activeDialog.Close() })
    $cancelButtonControl = $dialog.FindName('DlgCancel')
    if ($cancelButtonControl) {
        $cancelButtonControl.Add_Click({ $script:activeDialog.Tag = 'Cancel'; $script:activeDialog.Close() })
    }
    $dialog.Tag = $null
    return $dialog
}

function Show-AppMessage {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info'
    )
    $dialog = New-MessageDialog -Title $Title -Message $Message -Kind $Kind
    [void]$dialog.ShowDialog()
}

function Show-AppConfirm {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Warning'
    )
    $dialog = New-MessageDialog -Title $Title -Message $Message -Kind $Kind -ShowCancel
    [void]$dialog.ShowDialog()
    return ($dialog.Tag -eq 'OK')
}

function Open-LearnMoreUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return }
        Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
    } catch {
        Write-AppLog ('Could not open link: ' + $_.Exception.Message)
    }
}

function Select-FilePath {
    param([string]$Filter = 'All files (*.*)|*.*', [string]$Title = 'Select a file')
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = $Filter
    $dialog.Title = $Title
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog()) { return $dialog.FileName }
    return $null
}

function Select-FolderPath {
    param([string]$Description = 'Select a folder')
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return $null
}

function Start-BuildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][scriptblock]$OnLine,
        [Parameter(Mandatory)][scriptblock]$OnComplete
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $FilePath + '" ' + $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $script:buildJob = $process
    $script:buildCancelled = $false
    $script:buildStopRequested = $false
    $script:buildKillTarget = $null
    $script:buildCancelledAt = $null
    $script:buildExitedAt = $null
    $script:buildOutputLines = New-Object System.Collections.Generic.List[string]
    $script:buildErrorLines = New-Object System.Collections.Generic.List[string]
    $script:buildOnLine = $OnLine
    $script:buildOnComplete = $OnComplete
    $script:buildCompleted = @{ Done = $false }
    $script:buildStdoutTask = $null
    $script:buildStderrTask = $null

    $lineTimer = New-Object System.Windows.Threading.DispatcherTimer
    $lineTimer.Interval = [TimeSpan]::FromMilliseconds(120)
    $lineTimer.Add_Tick({
        param($sender, $eventArgs)
        try {
            $hasOutput = $false
            while ($true) {
                $task = $script:buildStdoutTask
                if ($task -and $task.IsCompleted) {
                    if ($task.IsFaulted -or $task.IsCanceled) {
                        # A killed process can fault or cancel a pending read;
                        # treat either one as end-of-stream.
                        $script:buildStdoutTask = $null
                        continue
                    }
                    $line = $task.Result
                    $script:buildStdoutTask = if ($null -ne $line) { $script:buildJob.StandardOutput.ReadLineAsync() } else { $null }
                    if ($null -ne $line) {
                        $script:buildOutputLines.Add($line) | Out-Null
                        if ($script:buildOnLine) {
                            try { & $script:buildOnLine $line 'stdout' } catch { Write-AppLog ('Build output handler error: ' + $_.Exception.Message) }
                        }
                        $hasOutput = $true
                        continue
                    }
                }
                break
            }
            while ($true) {
                $task = $script:buildStderrTask
                if ($task -and $task.IsCompleted) {
                    if ($task.IsFaulted -or $task.IsCanceled) {
                        $script:buildStderrTask = $null
                        continue
                    }
                    $line = $task.Result
                    $script:buildStderrTask = if ($null -ne $line) { $script:buildJob.StandardError.ReadLineAsync() } else { $null }
                    if ($null -ne $line) {
                        $script:buildErrorLines.Add($line) | Out-Null
                        if ($script:buildOnLine) {
                            try { & $script:buildOnLine $line 'stderr' } catch { Write-AppLog ('Build output handler error: ' + $_.Exception.Message) }
                        }
                        $hasOutput = $true
                        continue
                    }
                }
                break
            }
            if (-not $hasOutput) {
                $exited = Test-BuildProcessExited
                if ($exited -and -not $script:buildExitedAt) { $script:buildExitedAt = Get-Date }
                $stdoutDone = ($null -eq $script:buildStdoutTask)
                $stderrDone = ($null -eq $script:buildStderrTask)
                $cancelGrace = ($script:buildCancelled -and $script:buildCancelledAt -and ((Get-Date) - $script:buildCancelledAt).TotalSeconds -ge 2)
                $orphanGrace = ($exited -and $script:buildExitedAt -and ((Get-Date) - $script:buildExitedAt).TotalSeconds -ge 5)
                $streamsDone = ($stdoutDone -and $stderrDone) -or ($exited -and ($cancelGrace -or $orphanGrace))
                if (-not $script:buildCompleted.Done -and $streamsDone -and $exited) {
                    $script:buildCompleted.Done = $true
                    # A surviving grandchild can keep a redirected pipe open after
                    # the main writer exits; do not wait for that EOF forever.
                    $script:buildStdoutTask = $null
                    $script:buildStderrTask = $null
                    $exitCode = -1
                    try { $exitCode = $script:buildJob.ExitCode } catch { $exitCode = -1 }
                    $output = @($script:buildOutputLines) + @($script:buildErrorLines)
                    Write-AppLog ('Build process finished (exit code ' + $exitCode.ToString() + $(if ($script:buildCancelled) { '; cancelled' } else { '' }) + ').')
                    $sender.Stop()
                    if ($script:buildOnComplete) { & $script:buildOnComplete $exitCode $output }
                }
            }
        } catch {
            Write-AppLog ('Build pump error: ' + $_.Exception.Message)
        }
    })
    $lineTimer.Start()

    # The output streams only exist once the process has started. Reading
    # StandardOutput/StandardError before Start() returns null, which broke the
    # pump and (with $ErrorActionPreference = 'Stop') prevented the build from
    # ever launching.
    [void]$process.Start()
    $script:buildStdoutTask = $process.StandardOutput.ReadLineAsync()
    $script:buildStderrTask = $process.StandardError.ReadLineAsync()
    $script:buildLastLineTime = Get-Date
    return $process
}

function Test-BuildProcessExited {
    if (-not $script:buildJob) { return $true }
    try { return $script:buildJob.HasExited } catch { return $true }
}

function Stop-BuildProcess {
    if ($script:buildStopRequested) { return }
    $script:buildStopRequested = $true
    $script:buildCancelled = $true
    $script:buildCancelledAt = Get-Date
    Write-AppLog 'Cancellation requested; stopping the writer process and any download helpers.'
    $cancelButton = Find-Control 'BtnCancel'
    if ($cancelButton) { $cancelButton.IsEnabled = $false }
    Set-ProgressStatus -Text 'Cancelling...'
    Write-AppLog 'Cancelling...'
    if (-not $script:buildJob) {
        Write-AppLog 'No build process was running.'
        return
    }
    if (Test-BuildProcessExited) {
        Write-AppLog 'The build process had already exited.'
        return
    }

    # Kill the whole tree so helper processes (for example aria2c) stop too.
    # taskkill starts immediately and returns without waiting; a short dispatcher
    # tick then force-kills the main writer if it has not exited yet. This keeps
    # the UI thread free while cancellation is in flight. The tick reads the
    # target from a script variable: delegate handlers cannot see function locals.
    $script:buildKillTarget = $script:buildJob
    $killPsi = New-Object System.Diagnostics.ProcessStartInfo
    $killPsi.FileName = 'taskkill'
    $killPsi.Arguments = '/PID ' + $script:buildKillTarget.Id.ToString() + ' /T /F'
    $killPsi.UseShellExecute = $false
    $killPsi.CreateNoWindow = $true
    $killPsi.RedirectStandardOutput = $true
    $killPsi.RedirectStandardError = $true
    try {
        $script:buildKiller = [System.Diagnostics.Process]::Start($killPsi)
    } catch {
        Write-AppLog ('Could not start taskkill: ' + $_.Exception.Message)
    }
    $killTimer = New-Object System.Windows.Threading.DispatcherTimer
    $killTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $killTimer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        try {
            $target = $script:buildKillTarget
            if ($target -and -not $target.HasExited) { $target.Kill() }
        } catch { }
        Write-AppLog 'Writer process termination requested.'
    })
    $killTimer.Start()
    Write-AppLog 'Stopping the writer process tree.'
}

$script:app = [PSCustomObject]@{
    Catalog = $null
    BaseManifest = $null
    ProfilePaths = @()
    SelectedProfilePath = $null
    ContentMode = 'Prebuilt'
    RequiredBytes = 0
    RequiredBytesKnown = $false
    DiskInventory = @()
    SelectedDiskNumber = -1
    SelectedDiskSnapshot = $null
    Step = 1
}
$script:window = $null
$script:ui = @{}
$script:profileCards = @{}
$script:profileIndicators = @{}
$script:libraryRows = @()
$script:diskCards = @{}
$script:stageRows = @{}
$script:stageOrder = @()
$script:activeStageId = $null
$script:marqueeTimer = $null
$script:elapsedTimer = $null
$script:buildStartTime = $null
$script:buildLastLineTime = $null
$script:buildBarPercent = 0
$script:buildStagePercent = 0
$script:buildStopRequested = $false
$script:buildKillTarget = $null
$script:buildCancelledAt = $null
$script:buildExitedAt = $null
$script:downloadItems = @()
$script:downloadUseBytes = $false
$script:downloadTotalWeight = 0
$script:downloadCompletedWeight = 0
$script:downloadCurrentItem = $null
$script:downloadCurrentPercent = 0
$script:copyTotalCount = 0
$script:copyCompletedCount = 0

function Find-Control {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:ui.Contains($Name)) { return $script:ui[$Name] }
    $control = $script:window.FindName($Name)
    if ($control) { $script:ui[$Name] = $control }
    return $control
}

function New-UiText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Style = 'BodyText',
        [string]$Foreground = $null,
        [double]$FontSize = 0,
        [double]$Width = 0
    )
    $textBlock = New-Object System.Windows.Controls.TextBlock
    $textBlock.Style = $script:window.FindResource($Style)
    $textBlock.Text = $Text
    $textBlock.TextWrapping = 'Wrap'
    if ($Foreground) { $textBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Foreground)) }
    if ($FontSize -gt 0) { $textBlock.FontSize = $FontSize }
    if ($Width -gt 0) { $textBlock.Width = $Width }
    return $textBlock
}

function New-Badge {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Background,
        [Parameter(Mandatory)][string]$Foreground
    )
    $border = New-Object System.Windows.Controls.Border
    $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Background))
    $border.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $border.Padding = New-Object System.Windows.Thickness(6, 2, 6, 2)
    $border.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 11
    $label.FontWeight = 'SemiBold'
    $label.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Foreground))
    $border.Child = $label
    return $border
}

function Update-StepIndicator {
    param([Parameter(Mandatory)][int]$Step)
    $script:app.Step = $Step
    for ($i = 1; $i -le 4; $i++) {
        $dot = Find-Control ("StepDot" + $i)
        $dotText = Find-Control ("StepDotText" + $i)
        $line = Find-Control ("StepLine" + $i)
        if ($i -eq $Step) {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F6B9D'))
            $dotText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
            $dotText.FontWeight = 'Bold'
        } elseif ($i -lt $Step) {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1E9E5A'))
            $dotText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
            $dotText.FontWeight = 'Bold'
        } else {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
            $dotText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#5B6B7A'))
            $dotText.FontWeight = 'Normal'
        }
        if ($line -and $i -lt 4) {
            if ($i -lt $Step) {
                $line.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1E9E5A'))
            } else {
                $line.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#D5DDE5'))
            }
        }
    }
}

function Show-Step {
    param([Parameter(Mandatory)][int]$Step)
    $pages = @{
        1 = 'PageContent'
        2 = 'PageInstall'
        3 = 'PageSd'
        4 = 'PageReview'
        5 = 'PageProgress'
        6 = 'PageDone'
        7 = 'PageError'
    }
    foreach ($entry in $pages.GetEnumerator()) {
        $page = Find-Control $entry.Value
        if ($page) { $page.Visibility = if ([int]$entry.Key -eq $Step) { 'Visible' } else { 'Collapsed' } }
    }
    $footer = Find-Control 'FooterBar'
    if ($footer) { $footer.Visibility = if ($Step -le 4) { 'Visible' } else { 'Collapsed' } }
    $devButton = Find-Control 'BtnDeveloperTools'
    if ($devButton) { $devButton.Visibility = if ($Step -le 4) { 'Visible' } else { 'Collapsed' } }
    if ($Step -le 4) {
        Update-StepIndicator -Step $Step
        $backButton = Find-Control 'BtnBack'
        $continueButton = Find-Control 'BtnContinue'
        if ($backButton) { $backButton.Visibility = if ($Step -gt 1) { 'Visible' } else { 'Collapsed' } }
        if ($continueButton) {
            $continueButton.Content = if ($Step -eq 4) { 'Create Emergency Web Pi' } else { 'Continue' }
        }
        Update-ContinueButton
    }
}

function Test-ContentSelectionValid {
    # The library rows mirror the selected profile and the build contains exactly the
    # checked libraries, so "nothing checked" means nothing would be built.
    $checkedCount = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked }).Count
    return ($checkedCount -gt 0)
}

function Update-ContentSummary {
    $summary = Find-Control 'CustomizeSummary'
    if (-not $summary) { return }
    $checked = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked })
    if ($checked.Count -eq 0) {
        $summary.Text = 'No libraries selected yet.'
        $script:app.RequiredBytes = 0
        $script:app.RequiredBytesKnown = $true
        Update-CapacityPanel
        Update-ReviewSummary
        Update-ContinueButton
        return
    }
    $total = Get-SelectionTotals -Items @($checked | ForEach-Object { $_.Item })
    if ($total.KnownSize) {
        $summary.Text = ($checked.Count.ToString() + ' libraries selected - about ' + (Format-Bytes $total.TotalBytes) + ' to download')
    } else {
        $summary.Text = ($checked.Count.ToString() + ' libraries selected - total size cannot be estimated yet because some sizes are unknown')
    }
    $script:app.RequiredBytes = Get-RequiredBytesForLibraries -Items @($checked | ForEach-Object { $_.Item }) -BaseManifest $script:app.BaseManifest
    $script:app.RequiredBytesKnown = $total.KnownSize
    Update-CapacityPanel
    Update-ReviewSummary
    Update-ContinueButton
}

function Update-CapacityPanel {
    $panel = Find-Control 'CapacityPanel'
    $summary = Find-Control 'CapacitySummary'
    $fill = Find-Control 'CapacityFill'
    if (-not $panel -or -not $summary -or -not $fill) { return }
    if ($script:app.SelectedDiskNumber -lt 0) {
        $panel.Visibility = 'Collapsed'
        return
    }
    $panel.Visibility = 'Visible'
    $disk = $script:app.DiskInventory | Where-Object { $_.DiskNumber -eq $script:app.SelectedDiskNumber } | Select-Object -First 1
    if (-not $disk) {
        $panel.Visibility = 'Collapsed'
        return
    }
    if (-not $script:app.RequiredBytesKnown) {
        $summary.Text = 'Card: ' + (Format-Bytes $disk.Size) + '. Required size cannot be estimated yet - some library sizes are unknown.'
        $fill.Width = 0
        $fill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#B45309'))
        return
    }
    $required = $script:app.RequiredBytes
    $percent = 0
    if ($disk.Size -gt 0) { $percent = [Math]::Min(100, [Math]::Round(($required * 100.0) / $disk.Size)) }
    if ($required -gt $disk.Size) {
        $summary.Text = 'Needs about ' + (Format-Bytes $required) + ' but this card has ' + (Format-Bytes $disk.Size) + '. Choose a larger card.'
        $fill.Width = 300
        $fill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#B3261E'))
    } else {
        $summary.Text = 'Needs about ' + (Format-Bytes $required) + ' of ' + (Format-Bytes $disk.Size) + ' on this card.'
        $fill.Width = [Math]::Max(4, [Math]::Round(300.0 * $percent / 100.0))
        $fill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F6B9D'))
    }
}

function New-ProfileCard {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [bool]$Recommended = $false
    )
    $name = Get-ProfileDisplayName -ProfilePath $ProfilePath
    $description = Get-ProfileDescription -ProfilePath $ProfilePath
    $libraries = @(Get-ProfileLibraries -ProfilePath $ProfilePath -Catalog $script:app.Catalog)
    $totals = Get-SelectionTotals -Items $libraries
    $tags = @(Get-ProfileCategoryTags -ProfilePath $ProfilePath)

    $card = New-Object System.Windows.Controls.Primitives.ToggleButton
    $card.Style = $script:window.FindResource('CardRadio')
    $card.Width = 440
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 16, 16)
    $card.Tag = $ProfilePath

    $panel = New-Object System.Windows.Controls.StackPanel
    $headerRow = New-Object System.Windows.Controls.DockPanel
    $headerRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $titleText = New-UiText $name 'SectionLabel'
    $titleText.FontSize = 17
    $headerRow.Children.Add($titleText) | Out-Null
    [System.Windows.Controls.DockPanel]::SetDock($titleText, 'Left')
    $indicator = New-Object System.Windows.Controls.Border
    $indicator.Width = 18
    $indicator.Height = 18
    $indicator.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $indicator.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#9AA7B4'))
    $indicator.BorderThickness = New-Object System.Windows.Thickness(2)
    $indicator.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
    $indicator.VerticalAlignment = 'Center'
    $headerRow.Children.Add($indicator) | Out-Null
    [System.Windows.Controls.DockPanel]::SetDock($indicator, 'Right')
    $panel.Children.Add($headerRow) | Out-Null
    if ($Recommended) {
        $badgeRow = New-Object System.Windows.Controls.StackPanel
        $badgeRow.Orientation = 'Horizontal'
        $badgeRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $badgeRow.Children.Add((New-Badge 'Recommended' '#E3F2EA' '#1E7A46')) | Out-Null
        $panel.Children.Add($badgeRow) | Out-Null
    }
    $descText = New-UiText $description 'BodyText'
    $descText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#3E4C59'))
    $panel.Children.Add($descText) | Out-Null
    $metaText = New-UiText ((Format-Bytes $totals.TotalBytes) + ' - ' + $libraries.Count.ToString() + ' libraries') 'MetaText'
    $panel.Children.Add($metaText) | Out-Null
    if ($tags.Count -gt 0) {
        $tagRow = New-Object System.Windows.Controls.WrapPanel
        $tagRow.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        foreach ($tag in $tags) {
            $tagRow.Children.Add((New-Badge $tag '#EEF2F6' '#3E4C59')) | Out-Null
        }
        $panel.Children.Add($tagRow) | Out-Null
    }
    $card.Content = $panel

    $script:profileIndicators[$ProfilePath] = $indicator
    $script:profileCards[$ProfilePath] = $card

    $card.Add_Checked({
        param($sender, $eventArgs)
        $path = $sender.Tag
        $script:app.SelectedProfilePath = $path
        foreach ($entry in $script:profileCards.GetEnumerator()) {
            if ($entry.Key -ne $path) { $entry.Value.IsChecked = $false }
        }
        $indicator = $script:profileIndicators[$path]
        if ($indicator) {
            $indicator.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F6B9D'))
            $indicator.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F6B9D'))
        }
        Rebuild-LibraryRows
        Update-ContentSummary
    })
    $card.Add_Unchecked({
        param($sender, $eventArgs)
        $path = $sender.Tag
        $indicator = $script:profileIndicators[$path]
        if ($indicator) {
            $indicator.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
            $indicator.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#9AA7B4'))
        }
        if ($script:app.SelectedProfilePath -eq $path) {
            $script:app.SelectedProfilePath = $null
            Rebuild-LibraryRows
            Update-ContentSummary
        }
    })
    return $card
}

function Rebuild-LibraryRows {
    $listHost = Find-Control 'LibraryListHost'
    if (-not $listHost) { return }
    $listHost.Children.Clear()
    $script:libraryRows = @()
    $items = @()
    if ($script:app.SelectedProfilePath) {
        $items = @(Get-ProfileLibraries -ProfilePath $script:app.SelectedProfilePath -Catalog $script:app.Catalog)
    }
    foreach ($item in $items) {
        $row = New-Object System.Windows.Controls.CheckBox
        $row.Style = $script:window.FindResource('LibraryCheck')
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $row.IsChecked = $true

        $rowPanel = New-Object System.Windows.Controls.StackPanel
        $topRow = New-Object System.Windows.Controls.DockPanel
        $topRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
        $nameText = New-UiText $item.Name 'BodyText'
        $nameText.FontWeight = 'SemiBold'
        $topRow.Children.Add($nameText) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($nameText, 'Left')
        $sizeText = New-UiText (Format-Bytes $item.EstimatedBytes) 'MetaText'
        $sizeText.VerticalAlignment = 'Center'
        $topRow.Children.Add($sizeText) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($sizeText, 'Right')
        $rowPanel.Children.Add($topRow) | Out-Null

        $descText = New-UiText $item.Description 'MutedText'
        $descText.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
        $rowPanel.Children.Add($descText) | Out-Null

        if ($item.LearnMoreUrl) {
            $link = New-Object System.Windows.Controls.TextBlock
            $hyperlink = New-Object System.Windows.Documents.Hyperlink
            $hyperlink.NavigateUri = [Uri]$item.LearnMoreUrl
            $hyperlink.Inlines.Add('Learn more') | Out-Null
            $link.Inlines.Add($hyperlink) | Out-Null
            $hyperlink.Style = $script:window.FindResource('LinkText')
            $link.Tag = $item.LearnMoreUrl
            $link.Add_MouseLeftButtonUp({ param($sender, $eventArgs) Open-LearnMoreUrl -Url ([string]$sender.Tag) })
            $rowPanel.Children.Add($link) | Out-Null
        }

        $row.Content = $rowPanel
        $entry = [PSCustomObject]@{ CheckBox = $row; Item = $item }
        $script:libraryRows += ,$entry
        $row.Add_Checked({ Update-ContentSummary })
        $row.Add_Unchecked({ Update-ContentSummary })
        $listHost.Children.Add($row) | Out-Null
    }
    $expander = Find-Control 'CustomizeExpander'
    if ($expander) {
        $expander.IsExpanded = ($items.Count -gt 0)
    }
    Update-ContentSummary
}

function New-DiskCard {
    param([Parameter(Mandatory)]$Disk)
    $info = Get-DriveCardInfo -Disk $Disk
    $card = New-Object System.Windows.Controls.Primitives.ToggleButton
    $card.Style = $script:window.FindResource('CardRadio')
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)
    $card.Tag = $Disk.DiskNumber
    $card.IsEnabled = $info.Eligible

    $panel = New-Object System.Windows.Controls.StackPanel
    $headerRow = New-Object System.Windows.Controls.DockPanel
    $headerRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $titleText = New-UiText ($info.Title) 'SectionLabel'
    $titleText.FontSize = 16
    $headerRow.Children.Add($titleText) | Out-Null
    [System.Windows.Controls.DockPanel]::SetDock($titleText, 'Left')
    $pill = New-Badge $info.StatusText $(if ($info.StatusKind -eq 'Ready') { '#E3F2EA' } elseif ($info.StatusKind -eq 'TooSmall') { '#FDECEA' } else { '#FDF3E3' }) $(if ($info.StatusKind -eq 'Ready') { '#1E7A46' } elseif ($info.StatusKind -eq 'TooSmall') { '#B3261E' } else { '#B45309' })
    $pill.VerticalAlignment = 'Center'
    $headerRow.Children.Add($pill) | Out-Null
    [System.Windows.Controls.DockPanel]::SetDock($pill, 'Right')
    $panel.Children.Add($headerRow) | Out-Null

    $kindText = New-UiText $info.DriveKind 'MutedText'
    $panel.Children.Add($kindText) | Out-Null
    $capacityText = New-UiText ('Capacity: ' + (Format-Bytes $Disk.Size)) 'MetaText'
    $panel.Children.Add($capacityText) | Out-Null
    if ($info.Detail) {
        $detailText = New-UiText $info.Detail 'MetaText'
        $panel.Children.Add($detailText) | Out-Null
    }
    $card.Content = $panel

    $script:diskCards[$Disk.DiskNumber] = $card

    $card.Add_Checked({
        param($sender, $eventArgs)
        $number = [int]$sender.Tag
        $script:app.SelectedDiskNumber = $number
        $script:app.SelectedDiskSnapshot = ($script:app.DiskInventory | Where-Object { $_.DiskNumber -eq $number } | Select-Object -First 1)
        $warning = Find-Control 'SdWarning'
        if ($warning) { $warning.Visibility = 'Collapsed' }
        Update-CapacityPanel
        Update-ReviewSummary
        Update-ContinueButton
    })
    $card.Add_Unchecked({
        param($sender, $eventArgs)
        $number = [int]$sender.Tag
        if ($script:app.SelectedDiskNumber -eq $number) {
            $script:app.SelectedDiskNumber = -1
            $script:app.SelectedDiskSnapshot = $null
            Update-CapacityPanel
            Update-ReviewSummary
            Update-ContinueButton
        }
    })
    return $card
}

function Refresh-DiskList {
    $listHost = Find-Control 'DiskListHost'
    $statusText = Find-Control 'SdStatusText'
    $emptyState = Find-Control 'SdEmptyState'
    if (-not $listHost) { return }
    $listHost.Children.Clear()
    $script:diskCards = @{}

    $disks = @(Get-SelectableDisks)
    $script:app.DiskInventory = @($disks)
    $cards = @()
    foreach ($disk in $disks) {
        $cards += ,(New-DiskCard -Disk $disk)
    }
    foreach ($card in $cards) { $listHost.Children.Add($card) | Out-Null }

    $selectedStillThere = $false
    if ($script:app.SelectedDiskNumber -ge 0) {
        $selected = $disks | Where-Object { $_.DiskNumber -eq $script:app.SelectedDiskNumber } | Select-Object -First 1
        if ($selected -and $script:app.SelectedDiskSnapshot) {
            $snapshot = $script:app.SelectedDiskSnapshot
            if ($selected.Size -eq $snapshot.Size -and $selected.FriendlyName -eq $snapshot.FriendlyName -and $selected.BusType -eq $snapshot.BusType) {
                $selectedStillThere = $true
                $script:app.SelectedDiskSnapshot = $selected
                $card = $script:diskCards[$script:app.SelectedDiskNumber]
                if ($card) { $card.IsChecked = $true }
            }
        }
    }
    if (-not $selectedStillThere -and $script:app.SelectedDiskNumber -ge 0) {
        $script:app.SelectedDiskNumber = -1
        $script:app.SelectedDiskSnapshot = $null
        $warning = Find-Control 'SdWarning'
        if ($warning) {
            $warning.Text = 'The previously selected card was removed or changed. Please select the SD card again.'
            $warning.Visibility = 'Visible'
        }
    }

    if ($disks.Count -eq 0) {
        if ($statusText) { $statusText.Text = 'No removable drives were found.' }
        if ($emptyState) { $emptyState.Visibility = 'Visible' }
    } else {
        $eligible = @($disks | Where-Object { (Get-DriveCardInfo -Disk $_).StatusKind -eq 'Ready' })
        if ($statusText) {
            if ($eligible.Count -gt 0) {
                $statusText.Text = ($eligible.Count.ToString() + ' removable drive(s) ready. Select the SD card you want to erase.')
            } else {
                $statusText.Text = 'Removable drives were found, but none are ready yet. Check that an SD card is fully inserted.'
            }
        }
        if ($emptyState) { $emptyState.Visibility = 'Collapsed' }
    }
    Update-CapacityPanel
    Update-ReviewSummary
    Update-ContinueButton
}

function Get-SelectableDisks {
    $all = @(Get-Disk | Where-Object { $_.Size -gt 0 })
    foreach ($disk in $all) {
        $letters = @(Get-Partition -DiskNumber $disk.DiskNumber -ErrorAction SilentlyContinue |
            Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            ForEach-Object { [string]$_.DriveLetter })
        Add-Member -InputObject $disk -NotePropertyName DriveLetters -NotePropertyValue $letters -Force -ErrorAction SilentlyContinue
    }
    return @($all)
}

function Update-ReviewSummary {
    $contentControl = Find-Control 'RevContent'
    $installControl = Find-Control 'RevInstall'
    $cardControl = Find-Control 'RevCard'
    $sizeControl = Find-Control 'RevSize'
    $internetControl = Find-Control 'RevInternet'
    if (-not $contentControl) { return }

    # The review must summarize exactly what will be built: the checked libraries.
    $checked = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked })
    if ($checked.Count -gt 0) {
        $totals = Get-SelectionTotals -Items @($checked | ForEach-Object { $_.Item })
        if ($script:app.SelectedProfilePath) {
            $name = Get-ProfileDisplayName -ProfilePath $script:app.SelectedProfilePath
            $profileLibraries = @(Get-ProfileLibraries -ProfilePath $script:app.SelectedProfilePath -Catalog $script:app.Catalog)
            $contentControl.Text = $name + ' - ' + $checked.Count.ToString() + ' of ' + $profileLibraries.Count.ToString() + ' libraries, about ' + (Format-Bytes $totals.TotalBytes)
        } else {
            $contentControl.Text = 'Custom selection (' + $checked.Count.ToString() + ' libraries, about ' + (Format-Bytes $totals.TotalBytes) + ')'
        }
    } else {
        $contentControl.Text = 'No content selected'
    }
    if ($script:app.ContentMode -eq 'Prebuilt') {
        $installControl.Text = 'Prepare everything now - the library is downloaded on this PC and stored on the card. No Internet is needed on first boot.'
        $internetControl.Text = 'Internet on this PC: required to download the library now.'
    } else {
        $installControl.Text = 'Download content on first boot - the Pi downloads the library when it has Internet, then keeps it offline.'
        $internetControl.Text = 'Internet on the Raspberry Pi: required once, on first boot.'
    }
    if ($script:app.SelectedDiskNumber -ge 0) {
        $disk = $script:app.DiskInventory | Where-Object { $_.DiskNumber -eq $script:app.SelectedDiskNumber } | Select-Object -First 1
        if ($disk) {
            $cardControl.Text = $disk.FriendlyName + ' - disk ' + $disk.DiskNumber.ToString() + ' - ' + (Format-Bytes $disk.Size)
        } else {
            $cardControl.Text = 'No card selected'
        }
    } else {
        $cardControl.Text = 'No card selected'
    }
    if ($script:app.RequiredBytesKnown) {
        $sizeControl.Text = 'About ' + (Format-Bytes $script:app.RequiredBytes) + ' will be written to the card.'
    } else {
        $sizeControl.Text = 'The final size cannot be estimated yet because some library sizes are unknown.'
    }
}

function Update-ContinueButton {
    $button = Find-Control 'BtnContinue'
    if (-not $button) { return }
    $step = $script:app.Step
    $enabled = $true
    if ($step -eq 1) { $enabled = Test-ContentSelectionValid }
    if ($step -eq 3) {
        $enabled = ($script:app.SelectedDiskNumber -ge 0)
        if ($enabled -and $script:app.SelectedDiskSnapshot) {
            $disk = $script:app.DiskInventory | Where-Object { $_.DiskNumber -eq $script:app.SelectedDiskNumber } | Select-Object -First 1
            if (-not $disk) { $enabled = $false }
        }
    }
    if ($step -eq 4) {
        $enabled = (Test-ContentSelectionValid) -and ($script:app.SelectedDiskNumber -ge 0)
    }
    $button.IsEnabled = $enabled
}

function Set-BuildBarPercent {
    param([int]$Percent)
    $fill = Find-Control 'BuildBarFill'
    if (-not $fill) { return }
    $percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    # Overall progress is monotonic: a stage transition can only move the bar
    # forward, never reset it to zero.
    if (-not $script:buildBarPercent -or $percent -gt $script:buildBarPercent) {
        $script:buildBarPercent = $percent
    }
    $track = Find-Control 'BuildBarTrack'
    $trackWidth = 560
    if ($track) { $trackWidth = [Math]::Max(100, $track.ActualWidth) }
    $fill.Width = [Math]::Max(0, [Math]::Min($trackWidth, [Math]::Round($trackWidth * $script:buildBarPercent / 100.0)))
    $fill.Visibility = 'Visible'
}

function Start-Marquee {
    $fill = Find-Control 'BuildBarFill'
    if (-not $fill) { return }
    if (-not $script:marqueeTimer) {
        $script:marqueeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:marqueeTimer.Interval = [TimeSpan]::FromMilliseconds(60)
        $script:marqueeState = @{ Offset = 0.0; Direction = 1 }
        $script:marqueeTimer.Add_Tick({
            $track = Find-Control 'BuildBarTrack'
            $trackWidth = 560
            if ($track) { $trackWidth = [Math]::Max(100, $track.ActualWidth) }
            $fill = Find-Control 'BuildBarFill'
            if (-not $fill) { return }
            $barWidth = [Math]::Max(60, [Math]::Round($trackWidth * 0.25))
            $script:marqueeState.Offset = $script:marqueeState.Offset + 14 * $script:marqueeState.Direction
            if ($script:marqueeState.Offset -ge ($trackWidth - $barWidth)) { $script:marqueeState.Offset = $trackWidth - $barWidth; $script:marqueeState.Direction = -1 }
            if ($script:marqueeState.Offset -le 0) { $script:marqueeState.Offset = 0; $script:marqueeState.Direction = 1 }
            $fill.Width = $barWidth
            $fill.Visibility = 'Visible'
            [System.Windows.Controls.Canvas]::SetLeft($fill, $script:marqueeState.Offset)
        })
    }
    $fill.Visibility = 'Visible'
    $script:marqueeTimer.Start()
}

function Stop-Marquee {
    if ($script:marqueeTimer) { $script:marqueeTimer.Stop() }
    $fill = Find-Control 'BuildBarFill'
    if ($fill) { [System.Windows.Controls.Canvas]::SetLeft($fill, 0) }
}

function Set-CurrentStage {
    param([Parameter(Mandatory)][string]$StageId)
    if ($StageId -ne $script:activeStageId) {
        # Entering a stage means the previous stage finished; move the overall
        # bar to this stage's base instead of resetting it to zero.
        $script:activeStageId = $StageId
        $script:buildStagePercent = 0
        $base = Get-CreatorStageBasePercent -ContentMode $script:app.ContentMode -StageId $StageId
        Set-BuildBarPercent -Percent $base
    } else {
        $script:activeStageId = $StageId
    }
    foreach ($entry in $script:stageRows.GetEnumerator()) {
        $row = $entry.Value
        $dot = $row.Dot
        $label = $row.Label
        if ($entry.Key -eq $StageId) {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F6B9D'))
            $label.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1F2933'))
            $label.FontWeight = 'SemiBold'
        } elseif ($script:stageOrder.IndexOf($entry.Key) -lt $script:stageOrder.IndexOf($StageId)) {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1E9E5A'))
            $label.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#5B6B7A'))
            $label.FontWeight = 'Normal'
        } else {
            $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#D5DDE5'))
            $label.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#9AA7B4'))
            $label.FontWeight = 'Normal'
        }
    }
    # Only genuinely unmeasurable stages use the marquee; the write and copy
    # stages report real percentages now.
    $marqueeStages = @('partition', 'verify')
    if ($marqueeStages -contains $StageId) { Start-Marquee } else { Stop-Marquee }
    $cancelButton = Find-Control 'BtnCancel'
    if ($cancelButton) {
        $safe = Test-WriterCancellationSafe -StageId $StageId
        $cancelButton.IsEnabled = $safe
        $cancelNote = Find-Control 'CancelNote'
        if ($cancelNote) {
            if ($safe) {
                $cancelNote.Text = 'You can cancel now. The SD card will not be written.'
                $cancelNote.Visibility = 'Visible'
            } else {
                $cancelNote.Text = 'The SD card is being written. Do not remove the card and do not close the application.'
                $cancelNote.Visibility = 'Visible'
            }
        }
    }
}

function Set-ProgressStatus {
    param([string]$Text)
    $status = Find-Control 'ProgressStatus'
    if ($status -and $Text) { $status.Text = $Text }
}

function Set-ActiveStagePercent {
    param([Parameter(Mandatory)][string]$StageId, [Parameter(Mandatory)][int]$Percent)
    $script:buildStagePercent = [Math]::Max(0, [Math]::Min(100, $Percent))
    Set-BuildBarPercent -Percent (Get-CreatorOverallPercent -ContentMode $script:app.ContentMode -StageId $StageId -StagePercent $script:buildStagePercent)
}

function Complete-CurrentDownloadItem {
    if ($script:downloadCurrentItem -and -not $script:downloadCurrentItem.Completed) {
        $script:downloadCompletedWeight += [double]$script:downloadCurrentItem.Weight
        $script:downloadCurrentItem.Completed = $true
    }
    $script:downloadCurrentItem = $null
    $script:downloadCurrentPercent = 0
}

function Complete-DownloadItemByName {
    param([Parameter(Mandatory)][string]$Name)
    Complete-CurrentDownloadItem
    $item = @($script:downloadItems | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if ($item -and -not $item.Completed) {
        $script:downloadCompletedWeight += [double]$item.Weight
        $item.Completed = $true
    }
}

function Invoke-BuildLine {
    param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][string]$Stream)
    Add-Log $Line
    $script:buildLastLineTime = Get-Date
    $stage = Get-StageForWriterLine -Line $Line
    if ($stage) { Set-CurrentStage -StageId $stage }

    $systemPercent = Get-SystemPercentForLine -Line $Line
    if ($null -ne $systemPercent -and $script:activeStageId -eq 'system') {
        Set-ActiveStagePercent -StageId 'system' -Percent $systemPercent
        Set-ProgressStatus -Text ('Preparing system files - ' + $systemPercent.ToString() + '%')
        return
    }

    $writePercent = Get-WritePercentForLine -Line $Line
    if ($null -ne $writePercent -and $script:activeStageId -eq 'write') {
        Set-ActiveStagePercent -StageId 'write' -Percent $writePercent
        Set-ProgressStatus -Text ('Writing the appliance to the SD card - ' + $writePercent.ToString() + '%')
        return
    }

    if ($script:activeStageId -eq 'download') {
        if ($Line -match '^Downloading: (.+)$') {
            Complete-CurrentDownloadItem
            $name = $Matches[1]
            $item = @($script:downloadItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
            if (-not $item) {
                $item = [PSCustomObject]@{ Name = $name; Weight = 1.0; Completed = $false }
                $script:downloadItems += ,$item
                $script:downloadTotalWeight += 1.0
            }
            $script:downloadCurrentItem = $item
            $script:downloadCurrentPercent = 0
            $percent = Get-DownloadStagePercent -CompletedWeight $script:downloadCompletedWeight -CurrentWeight 0 -CurrentPercent 0 -TotalWeight $script:downloadTotalWeight
            Set-ActiveStagePercent -StageId 'download' -Percent $percent
            Set-ProgressStatus -Text ('Downloading content - ' + $name)
            return
        }
        if ($Line -match '^Using cached: (.+)$') {
            Complete-DownloadItemByName -Name $Matches[1]
            $percent = Get-DownloadStagePercent -CompletedWeight $script:downloadCompletedWeight -CurrentWeight 0 -CurrentPercent 0 -TotalWeight $script:downloadTotalWeight
            Set-ActiveStagePercent -StageId 'download' -Percent $percent
            Set-ProgressStatus -Text ('Using cached content - ' + $Matches[1])
            return
        }
        if ($Line -match '^Content download complete') {
            Complete-CurrentDownloadItem
            Set-ActiveStagePercent -StageId 'download' -Percent 100
            Set-ProgressStatus -Text 'Selected content is ready.'
            return
        }
        $filePercent = Get-DownloadPercentForLine -Line $Line
        if ($null -ne $filePercent) {
            $script:downloadCurrentPercent = $filePercent
            $currentWeight = 0
            if ($script:downloadCurrentItem) { $currentWeight = [double]$script:downloadCurrentItem.Weight }
            $percent = Get-DownloadStagePercent -CompletedWeight $script:downloadCompletedWeight -CurrentWeight $currentWeight -CurrentPercent $filePercent -TotalWeight $script:downloadTotalWeight
            Set-ActiveStagePercent -StageId 'download' -Percent $percent
            if ($script:downloadCurrentItem) {
                Set-ProgressStatus -Text ('Downloading content - ' + [string]$script:downloadCurrentItem.Name + ' - ' + $filePercent.ToString() + '% of this file')
            } else {
                Set-ProgressStatus -Text ('Downloading content - ' + $filePercent.ToString() + '%')
            }
            return
        }
    }

    if ($script:activeStageId -eq 'copy' -and $Line -match '^Copied: (.+)$') {
        $script:copyCompletedCount += 1
        $percent = Get-ItemStagePercent -CompletedCount $script:copyCompletedCount -TotalCount $script:copyTotalCount
        Set-ActiveStagePercent -StageId 'copy' -Percent $percent
        Set-ProgressStatus -Text ('Copied ' + $Matches[1])
        return
    }

    $statusText = Get-WriterStatusTextForLine -Line $Line
    if ($statusText) {
        Set-ProgressStatus -Text $statusText
        return
    }
    if ($stage) {
        $statusMap = @{
            'requirements' = 'Checking requirements.'
            'system' = 'Preparing system files.'
            'download' = 'Downloading selected content.'
            'write' = 'Writing the appliance to the SD card. Do not remove the card.'
            'partition' = 'Preparing the SD card.'
            'copy' = 'Copying files to the SD card.'
            'verify' = 'Verifying the SD card.'
            'done' = 'Finished.'
        }
        if ($statusMap.Contains($stage)) { Set-ProgressStatus -Text $statusMap[$stage] }
    }
}

function Build-StageList {
    $listHost = Find-Control 'StageListHost'
    if (-not $listHost) { return }
    $listHost.Children.Clear()
    $script:stageRows = @{}
    $script:stageOrder = @()
    $stages = @(Get-CreatorStages -ContentMode $script:app.ContentMode)
    foreach ($stage in $stages) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 12
        $dot.Height = 12
        $dot.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $dot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#D5DDE5'))
        $dot.VerticalAlignment = 'Top'
        $dot.Margin = New-Object System.Windows.Thickness(0, 4, 10, 0)
        $label = New-UiText $stage.Label 'BodyText'
        $label.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#9AA7B4'))
        $row.Children.Add($dot) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
        $row.Children.Add($label) | Out-Null
        $entry = [PSCustomObject]@{ Dot = $dot; Label = $label }
        $script:stageRows[$stage.Id] = $entry
        $script:stageOrder += ,$stage.Id
        $listHost.Children.Add($row) | Out-Null
    }
}

function Write-GeneratedProfileFile {
    param([Parameter(Mandatory)][string[]]$Entries)
    $dir = Join-Path $script:workspaceDirectory 'generated-profiles'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('creator-profile-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
    Set-Content -Path $path -Value $Entries -Encoding ASCII
    return $path
}

function Test-SelectedDiskStillValid {
    if ($script:app.SelectedDiskNumber -lt 0) { return $false }
    $snapshot = $script:app.SelectedDiskSnapshot
    if (-not $snapshot) { return $false }
    $current = @(Get-SelectableDisks) | Where-Object { $_.DiskNumber -eq $script:app.SelectedDiskNumber } | Select-Object -First 1
    if (-not $current) { return $false }
    if ($current.Size -ne $snapshot.Size) { return $false }
    if ($current.FriendlyName -ne $snapshot.FriendlyName) { return $false }
    if ($current.BusType -ne $snapshot.BusType) { return $false }
    $info = Get-DriveCardInfo -Disk $current
    if ($info.StatusKind -ne 'Ready') { return $false }
    $script:app.SelectedDiskSnapshot = $current
    return $true
}

function Start-CreatorBuild {
    # The build contains exactly the checked libraries; the creator gates Continue on
    # at least one checked library, so an empty selection is an error, not a fallback.
    $checked = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked })
    if ($checked.Count -eq 0) {
        Show-AppMessage -Kind Error -Title 'No content selected' -Message 'Please choose a content profile or select at least one library.'
        return
    }
    if ($script:buildJob -and -not (Test-BuildProcessExited)) {
        Write-AppLog 'A build is already running; ignoring the new build request.'
        return
    }

    $entries = @($checked | ForEach-Object { $_.Item.SourceUrl })
    $profilePath = Write-GeneratedProfileFile -Entries $entries
    Write-AppLog ('Creator build starting with ' + $entries.Count.ToString() + ' libraries.')

    $estimate = Get-PreflightEstimate -Items @($checked | ForEach-Object { $_.Item }) -BaseManifest $script:app.BaseManifest
    $script:app.RequiredBytes = $estimate.RequiredBytes
    $script:app.RequiredBytesKnown = $true

    $totals = Get-SelectionTotals -Items @($checked | ForEach-Object { $_.Item })
    $script:downloadUseBytes = ($totals.KnownSize -and $totals.TotalBytes -gt 0)
    $script:downloadItems = @($checked | ForEach-Object {
        $name = Resolve-ZimFileName -Url $_.Item.SourceUrl
        $weight = if ($script:downloadUseBytes) { [double]$_.Item.EstimatedBytes } else { 1.0 }
        [PSCustomObject]@{ Name = $name; Weight = $weight; Completed = $false }
    })
    $script:downloadTotalWeight = 0
    foreach ($item in $script:downloadItems) { $script:downloadTotalWeight += [double]$item.Weight }
    $script:downloadCompletedWeight = 0
    $script:downloadCurrentItem = $null
    $script:downloadCurrentPercent = 0
    $script:copyTotalCount = if ($script:app.ContentMode -eq 'Prebuilt') { $checked.Count } else { 0 }
    $script:copyCompletedCount = 0

    $wifi = New-WifiCredentials
    $configDir = Join-Path $script:workspaceDirectory 'config'
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $configPath = Join-Path $configDir 'dynamic-appliance-config.json'
    Set-Content -Path $configPath -Value (New-ApplianceConfigJsonText -Wifi $wifi) -Encoding UTF8

    $arguments = New-PrebuiltBuildArguments `
        -DiskNumber $script:app.SelectedDiskNumber `
        -ProfilePath $profilePath `
        -DeviceConfigPath $configPath `
        -ContentDir $script:cacheDirectory `
        -WorkspaceDir $script:workspaceDirectory `
        -ReleaseRepo "MikeyMan83/emergency-web-pi" `
        -ContentMode $script:app.ContentMode

    $script:prebuiltFlow = $true
    $scriptToRun = $prebuiltScript
    $script:buildStartTime = Get-Date
    $script:buildBarPercent = 0
    $script:buildStagePercent = 0
    $script:buildCancelled = $false
    $script:buildStopRequested = $false
    $script:buildCancelledAt = $null
    $script:buildExitedAt = $null
    $script:baseImageRetryDone = $false
    Show-Step -Step 5
    Build-StageList
    Set-CurrentStage -StageId 'requirements'
    Set-ProgressStatus -Text 'Starting the build...'
    Add-Log 'Starting the build process.'
    $titleControl = Find-Control 'ProgressTitle'
    if ($titleControl) { $titleControl.Text = 'Creating your Emergency Web Pi' }
    $elapsedControl = Find-Control 'ProgressElapsed'
    if ($elapsedControl) { $elapsedControl.Text = '' }
    Start-ElapsedTimer

    $onLine = {
        param([string]$Line, [string]$Stream)
        Invoke-BuildLine -Line $Line -Stream $Stream
    }
    $onComplete = {
        param([int]$ExitCode, [string[]]$Output)
        Complete-CreatorBuild -ExitCode $ExitCode -Output $Output
    }
    Start-BuildProcess -FilePath $scriptToRun -Arguments $arguments -OnLine $onLine -OnComplete $onComplete
    Add-Log 'Build process started.'
}

function Start-ElapsedTimer {
    if ($script:elapsedTimer) { $script:elapsedTimer.Stop() }
    $script:elapsedTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:elapsedTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:elapsedTimer.Add_Tick({
        if (-not $script:buildStartTime) { return }
        $elapsed = (Get-Date) - $script:buildStartTime
        $text = 'Elapsed: '
        if ($elapsed.TotalHours -ge 1) {
            $text += ([int]$elapsed.TotalHours).ToString() + ' h ' + $elapsed.Minutes.ToString('00') + ' min'
        } elseif ($elapsed.TotalMinutes -ge 1) {
            $text += ([int]$elapsed.TotalMinutes).ToString() + ' min ' + $elapsed.Seconds.ToString('00') + ' s'
        } else {
            $text += $elapsed.Seconds.ToString() + ' s'
        }
        $control = Find-Control 'ProgressElapsed'
        if ($control) { $control.Text = $text }
        # The writer now reports progress for every long operation, so a long
        # silence while the build runs means the current step is stuck.
        if ($script:buildJob -and -not $script:buildCompleted.Done -and -not $script:buildCancelled -and $script:buildLastLineTime) {
            $silent = (Get-Date) - $script:buildLastLineTime
            if ($silent.TotalSeconds -ge 180) {
                $status = Find-Control 'ProgressStatus'
                if ($status) {
                    $status.Text = ('Still working - no progress reported for ' + ([int]$silent.TotalMinutes).ToString() + ' min.')
                }
            }
        }
    })
    $script:elapsedTimer.Start()
}

function Complete-CreatorBuild {
    param([int]$ExitCode, [string[]]$Output)
    if ($script:elapsedTimer) { $script:elapsedTimer.Stop() }
    Stop-Marquee
    $outputText = @($Output) -join [Environment]::NewLine
    if ($ExitCode -eq 0) {
        Set-CurrentStage -StageId 'done'
        Set-ProgressStatus -Text 'Finished.'
        Set-BuildBarPercent -Percent 100
        Show-Completion
        return
    }
    if (-not $script:buildCancelled -and $outputText.Contains('BASE_IMAGE_UNAVAILABLE') -and -not $script:baseImageRetryDone) {
        $script:baseImageRetryDone = $true
        Write-AppLog 'Base image download failed; asking the user for a local Emergency Web Pi base image.'
        $imagePath = Select-FilePath -Filter 'Emergency Web Pi base image (*.img;*.img.gz;*.001)|*.img;*.img.gz;*.001|All files (*.*)|*.*' -Title 'Select the Emergency Web Pi base image'
        if ($imagePath) {
            Write-AppLog ('Retrying with local base image: ' + $imagePath)
            $manifestPath = Get-ChildItem -Path (Split-Path -Parent $imagePath) -Filter 'ewp-base-*.img.manifest.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $manifestPath) { $manifestPath = Get-Item -Path ($imagePath + '.manifest.json') -ErrorAction SilentlyContinue }
            if (-not $manifestPath) {
                $manifestPath = Select-FilePath -Filter 'Emergency Web Pi base image manifest (*.img.manifest.json)|*.img.manifest.json|All files (*.*)|*.*' -Title 'Select the base image manifest'
            }
            if ($manifestPath) { Write-AppLog ('Using local base image manifest: ' + $manifestPath.FullName) }
            $checked = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked })
            $entries = @($checked | ForEach-Object { $_.Item.SourceUrl })
            $profilePath = Write-GeneratedProfileFile -Entries $entries
            $wifiConfigPath = Join-Path $script:workspaceDirectory 'config\dynamic-appliance-config.json'
            $retryArgs = @{
                DiskNumber = $script:app.SelectedDiskNumber
                ProfilePath = $profilePath
                DeviceConfigPath = $wifiConfigPath
                ContentDir = $script:cacheDirectory
                WorkspaceDir = $script:workspaceDirectory
                ReleaseRepo = 'MikeyMan83/emergency-web-pi'
                ContentMode = $script:app.ContentMode
                ImagePathOverride = $imagePath
            }
            if ($manifestPath) { $retryArgs['ManifestPathOverride'] = $manifestPath.FullName }
            $arguments = New-PrebuiltBuildArguments @retryArgs
            # A retry is a new build: reset the whole-workflow progress state.
            $script:buildBarPercent = 0
            $script:buildStagePercent = 0
            $script:activeStageId = $null
            $script:downloadCompletedWeight = 0
            $script:downloadCurrentItem = $null
            $script:downloadCurrentPercent = 0
            foreach ($item in $script:downloadItems) { $item.Completed = $false }
            $script:copyCompletedCount = 0
            Set-CurrentStage -StageId 'requirements'
            Set-ProgressStatus -Text 'Starting the build...'
            Add-Log 'Starting the build process.'
            $onLine = {
                param([string]$Line, [string]$Stream)
                Invoke-BuildLine -Line $Line -Stream $Stream
            }
            $onComplete = {
                param([int]$RetryExitCode, [string[]]$RetryOutput)
                Complete-CreatorBuild -ExitCode $RetryExitCode -Output $RetryOutput
            }
            Start-BuildProcess -FilePath $scriptToRun -Arguments $arguments -OnLine $onLine -OnComplete $onComplete
            Add-Log 'Build process started.'
            return
        }
    }
    Show-BuildError -ExitCode $ExitCode -Output $outputText -Cancelled $script:buildCancelled
}

function Get-ApplianceWifiSsid {
    $configPath = Join-Path $script:workspaceDirectory 'config\dynamic-appliance-config.json'
    if (Test-Path $configPath) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($config.ap.ssid) { return [string]$config.ap.ssid }
    }
    return 'EmergencyWebPi'
}

function Get-ApplianceWifiPassword {
    $configPath = Join-Path $script:workspaceDirectory 'config\dynamic-appliance-config.json'
    if (Test-Path $configPath) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($config.ap.password) { return [string]$config.ap.password }
    }
    return ''
}

function Show-BuildError {
    param(
        [int]$ExitCode,
        [string]$Output,
        [bool]$Cancelled
    )
    Stop-Marquee
    $titleControl = Find-Control 'ProgressTitle'
    if ($titleControl) { $titleControl.Text = 'The Emergency Web Pi could not be created' }
    $messageControl = Find-Control 'ErrorMessage'
    $hintControl = Find-Control 'ErrorHint'
    $detailsExpander = Find-Control 'ErrorDetailsExpander'
    $logTail = Find-Control 'ErrorLogTail'
    if ($detailsExpander) { $detailsExpander.IsExpanded = $false }
    if ($logTail) {
        $script:logTargets.Remove($logTail) | Out-Null
        $script:logTargets.Add($logTail)
    }

    if ($Cancelled) {
        if ($messageControl) { $messageControl.Text = 'The operation was cancelled.' }
        if ($hintControl) { $hintControl.Text = 'No changes were made to the SD card. You can go back and try again.' }
    } elseif ($Output.Contains('BASE_IMAGE_UNAVAILABLE')) {
        if ($messageControl) { $messageControl.Text = 'The Emergency Web Pi base image could not be downloaded.' }
        if ($hintControl) { $hintControl.Text = 'Check the Internet connection on this PC, then try again. If you already downloaded the ewp-base files, select them when prompted. The SD card was not modified.' }
    } elseif ($Output.Contains('Refusing to write')) {
        if ($messageControl) { $messageControl.Text = 'The selected drive was rejected by the safety checks.' }
        if ($hintControl) { $hintControl.Text = 'Make sure you selected a removable SD card, then try again.' }
    } elseif ($Output -match 'Not enough free space on the workspace drive') {
        if ($messageControl) { $messageControl.Text = 'This PC does not have enough free disk space for the base image.' }
        if ($hintControl) { $hintControl.Text = 'Free up space on the drive that stores the Emergency Web Pi workspace, then try again. The SD card was not modified.' }
    } elseif ($Output -match 'Not enough free space on the SD card|not enough free space|insufficient') {
        if ($messageControl) { $messageControl.Text = 'The SD card does not have enough free space.' }
        if ($hintControl) { $hintControl.Text = 'Use a larger SD card, or choose a smaller content profile.' }
    } elseif ($Output.Contains('aria2c.exe')) {
        if ($messageControl) { $messageControl.Text = 'The download tool (aria2) is missing from the bundle.' }
        if ($hintControl) { $hintControl.Text = 'Please extract the full Emergency Web Pi ZIP again and run it from the extracted folder.' }
    } else {
        if ($messageControl) { $messageControl.Text = 'Something went wrong while creating the Emergency Web Pi (exit code ' + $ExitCode.ToString() + ').' }
        if ($hintControl) { $hintControl.Text = 'The SD card may be partially written - it is not safe to use. Review the log below, then try again with the same or a different card.' }
    }
    Show-Step -Step 7
}

function Show-Completion {
    if ($script:elapsedTimer) { $script:elapsedTimer.Stop() }
    $ssid = Get-ApplianceWifiSsid
    $password = Get-ApplianceWifiPassword
    $ssidControl = Find-Control 'WifiSsidText'
    $passwordControl = Find-Control 'WifiPasswordText'
    if ($ssidControl) { $ssidControl.Text = $ssid }
    if ($passwordControl) { $passwordControl.Text = $password }
    $labelPath = Join-Path $script:workspaceDirectory 'EmergencyWebPi-WiFi-Label.html'
    try {
        $html = New-WifiLabelHtml -Ssid $ssid -Password $password -Version $script:appVersion
        Set-Content -Path $labelPath -Value $html -Encoding UTF8
        $note = Find-Control 'WifiLabelNote'
        if ($note) { $note.Text = 'A Wi-Fi label was saved to: ' + $labelPath }
    } catch {
        Write-AppLog ('Could not write the Wi-Fi label: ' + $_.Exception.Message)
    }
    Show-Step -Step 6
}

function New-CreatorWindow {
    $window = Read-XamlWindow -RelativePath 'MainWindow.xaml'
    $script:window = $window
    Install-UnhandledExceptionHandlers

    $versionText = Find-Control 'VersionText'
    if ($versionText) { $versionText.Text = 'Version ' + $script:appVersion }

    $profileHost = Find-Control 'ProfileCardHost'
    if ($profileHost) {
        $order = @('emergency-medical', 'essential-web', 'practical-repair', 'medical-survival')
        $sortedPaths = @($script:app.ProfilePaths | Sort-Object {
            $sortName = Get-ProfileKey -ProfilePath $_
            $sortIndex = $order.IndexOf($sortName)
            if ($sortIndex -lt 0) { 99 } else { $sortIndex }
        })
        foreach ($profilePath in $sortedPaths) {
            $card = New-ProfileCard -ProfilePath $profilePath -Recommended ((Get-ProfileKey -ProfilePath $profilePath) -eq 'medical-survival')
            $profileHost.Children.Add($card) | Out-Null
        }
    }

    $optPrebuilt = Find-Control 'OptPrebuilt'
    $optFirstBoot = Find-Control 'OptFirstBoot'
    if ($optPrebuilt) {
        $optPrebuilt.IsChecked = ($script:app.ContentMode -eq 'Prebuilt')
        $optPrebuilt.Add_Checked({
            $script:app.ContentMode = 'Prebuilt'
            $peer = Find-Control 'OptFirstBoot'
            if ($peer -and $peer.IsChecked) { $peer.IsChecked = $false }
            Update-ReviewSummary
        })
    }
    if ($optFirstBoot) {
        $optFirstBoot.IsChecked = ($script:app.ContentMode -eq 'FirstBoot')
        $optFirstBoot.Add_Checked({
            $script:app.ContentMode = 'FirstBoot'
            $peer = Find-Control 'OptPrebuilt'
            if ($peer -and $peer.IsChecked) { $peer.IsChecked = $false }
            Update-ReviewSummary
        })
    }
    if ($optPrebuilt -and $optFirstBoot) {
        $optPrebuilt.Add_Unchecked({
            $peer = Find-Control 'OptFirstBoot'
            if (-not $peer -or -not $peer.IsChecked) {
                $self = Find-Control 'OptPrebuilt'
                if ($self) { $self.IsChecked = $true }
            }
        })
        $optFirstBoot.Add_Unchecked({
            $peer = Find-Control 'OptPrebuilt'
            if (-not $peer -or -not $peer.IsChecked) {
                $fallback = Find-Control 'OptPrebuilt'
                if ($fallback) { $fallback.IsChecked = $true }
            }
        })
    }

    $btnSelectAll = Find-Control 'BtnSelectAll'
    $btnSelectNone = Find-Control 'BtnSelectNone'
    if ($btnSelectAll) { $btnSelectAll.Add_Click({ foreach ($row in $script:libraryRows) { $row.CheckBox.IsChecked = $true } }) }
    if ($btnSelectNone) { $btnSelectNone.Add_Click({ foreach ($row in $script:libraryRows) { $row.CheckBox.IsChecked = $false } }) }

    $btnRefreshDisks = Find-Control 'BtnRefreshDisks'
    if ($btnRefreshDisks) { $btnRefreshDisks.Add_Click({ Refresh-DiskList }) }
    $sdEmptyRefresh = Find-Control 'SdEmptyRefresh'
    if ($sdEmptyRefresh) { $sdEmptyRefresh.Add_Click({ Refresh-DiskList }) }

    $btnBack = Find-Control 'BtnBack'
    if ($btnBack) {
        $btnBack.Add_Click({
            if ($script:app.Step -gt 1 -and $script:app.Step -le 4) { Show-Step -Step ($script:app.Step - 1) }
        })
    }
    $btnContinue = Find-Control 'BtnContinue'
    if ($btnContinue) {
        $btnContinue.Add_Click({
            $step = $script:app.Step
            if ($step -eq 1) {
                if (-not (Test-ContentSelectionValid)) { return }
                Show-Step -Step 2
            } elseif ($step -eq 2) {
                Show-Step -Step 3
                Refresh-DiskList
            } elseif ($step -eq 3) {
                if ($script:app.SelectedDiskNumber -lt 0) { return }
                Update-ReviewSummary
                Show-Step -Step 4
            } elseif ($step -eq 4) {
                Invoke-ReviewConfirmed
            }
        })
    }

    $btnCancel = Find-Control 'BtnCancel'
    if ($btnCancel) {
        $btnCancel.Add_Click({
            if (Test-WriterCancellationSafe -StageId $script:activeStageId) {
                $confirmed = Show-AppConfirm -Kind Warning -Title 'Cancel the operation?' -Message 'The operation will stop. The SD card has not been written yet, so it is safe to cancel now.'
                if ($confirmed) { Stop-BuildProcess }
            }
        })
    }

    $detailsExpander = Find-Control 'DetailsExpander'
    if ($detailsExpander) {
        $logTail = Find-Control 'LogTail'
        if ($logTail) { $script:logTargets.Add($logTail) }
    }

    $btnShowInstructions = Find-Control 'BtnShowInstructions'
    if ($btnShowInstructions) {
        $btnShowInstructions.Add_Click({
            Show-AppMessage -Kind Info -Title 'Set up your Emergency Web Pi' -Message ("1. Safely eject the SD card from this PC.`n2. Insert it into the Raspberry Pi.`n3. Power on the Pi.`n4. Connect to the Wi-Fi network named '" + (Get-ApplianceWifiSsid) + "'.`n5. Open a browser and go to the local offline library shown on the welcome page.")
        })
    }
    $btnViewLog = Find-Control 'BtnViewLog'
    if ($btnViewLog) {
        $btnViewLog.Add_Click({
            $expander = Find-Control 'DetailsExpander'
            if ($expander) { $expander.IsExpanded = $true }
        })
    }
    $btnFinish = Find-Control 'BtnFinish'
    if ($btnFinish) { $btnFinish.Add_Click({ $script:window.Close() }) }
    $btnBackToReview = Find-Control 'BtnBackToReview'
    if ($btnBackToReview) {
        $btnBackToReview.Add_Click({
            $script:prebuiltFlow = $false
            Refresh-DiskList
            Show-Step -Step 4
        })
    }
    $btnErrorFinish = Find-Control 'BtnErrorFinish'
    if ($btnErrorFinish) { $btnErrorFinish.Add_Click({ $script:window.Close() }) }

    $btnDeveloperTools = Find-Control 'BtnDeveloperTools'
    if ($btnDeveloperTools) { $btnDeveloperTools.Add_Click({ Show-DeveloperTools }) }

    $recommendedPath = $script:app.ProfilePaths | Where-Object { (Get-ProfileKey -ProfilePath $_) -eq 'medical-survival' } | Select-Object -First 1
    if (-not $recommendedPath -and $script:app.ProfilePaths.Count -gt 0) { $recommendedPath = $script:app.ProfilePaths[0] }
    if ($recommendedPath) {
        $card = $script:profileCards[$recommendedPath]
        if ($card) { $card.IsChecked = $true }
    }

    Show-Step -Step 1
    Refresh-DiskList
    return $window
}

function Invoke-ReviewConfirmed {
    if (-not (Test-SelectedDiskStillValid)) {
        Show-AppMessage -Kind Warning -Title 'SD card changed' -Message 'The selected SD card is no longer available or has changed. Please select it again.'
        Refresh-DiskList
        Show-Step -Step 3
        return
    }
    $disk = $script:app.SelectedDiskSnapshot
    $dialog = Read-XamlWindow -RelativePath 'ConfirmErase.xaml'
    $title = $dialog.FindName('ConfirmTitle')
    $device = $dialog.FindName('ConfirmDevice')
    $body = $dialog.FindName('ConfirmBody')
    if ($title) { $title.Text = 'Erase ' + $disk.FriendlyName + '?' }
    if ($device) { $device.Text = $disk.FriendlyName + ' - disk ' + $disk.DiskNumber.ToString() + ' - ' + (Format-Bytes $disk.Size) }
    if ($body) {
        $body.Text = 'Creating the Emergency Web Pi will erase ALL existing data on this card. This cannot be undone. Make sure you selected the correct SD card.'
    }
    $cancelButton = $dialog.FindName('BtnConfirmCancel')
    $eraseButton = $dialog.FindName('BtnConfirmErase')
    $script:activeDialog = $dialog
    $cancelButton.Add_Click({ $script:activeDialog.Tag = 'Cancel'; $script:activeDialog.Close() })
    $eraseButton.Add_Click({ $script:activeDialog.Tag = 'Erase'; $script:activeDialog.Close() })
    $dialog.Owner = $script:window
    [void]$dialog.ShowDialog()
    if ($dialog.Tag -ne 'Erase') { return }
    if (-not (Test-SelectedDiskStillValid)) {
        Show-AppMessage -Kind Warning -Title 'SD card changed' -Message 'The selected SD card changed again. Please select it once more.'
        Refresh-DiskList
        Show-Step -Step 3
        return
    }
    Start-CreatorBuild
}

function Test-WslReady {
    try {
        $wsl = Get-Command wsl -ErrorAction Stop
        $status = & wsl --status 2>$null
        if ($status -match 'Default Distribution:\s*Ubuntu') { return $true }
        $list = & wsl --list --quiet 2>$null
        if ($list -match 'Ubuntu') { return $true }
        return $false
    } catch {
        return $false
    }
}

function Show-WslSetupGuidance {
    Show-AppMessage -Kind Info -Title 'Set up WSL for the developer build' -Message ("The developer (dynamic) build runs inside WSL with Ubuntu. To set it up, open a Windows terminal as administrator and run:`n`n    wsl --install -d Ubuntu`n`nThen restart the PC and run this step again.")
}

function Resolve-DevEntries {
    $profilePath = $script:app.SelectedProfilePath
    $items = @()
    if ($profilePath) {
        $items = @(Get-ProfileLibraries -ProfilePath $profilePath -Catalog $script:app.Catalog)
    } else {
        $checked = @($script:libraryRows | Where-Object { $_.CheckBox.IsChecked })
        $items = @($checked | ForEach-Object { $_.Item })
    }
    $entries = @($items | ForEach-Object { $_.SourceUrl })
    $profileFile = Write-GeneratedProfileFile -Entries $entries
    return $profileFile
}

function Show-DeveloperTools {
    $window = Read-XamlWindow -RelativePath 'DeveloperTools.xaml'
    $window.Owner = $script:window
    $script:devWindow = $window
    $script:devUi = @{}
    $script:devFind = { param([string]$Name)
        if ($script:devUi.Contains($Name)) { return $script:devUi[$Name] }
        $control = $script:devWindow.FindName($Name)
        if ($control) { $script:devUi[$Name] = $control }
        return $control
    }
    $find = $script:devFind

    $baseInfo = & $find 'DevBaseInfo'
    $base = Get-PinnedBaseImageInfo -RepoRoot $script:repoRoot
    if ($base) {
        $baseInfo.Text = $base.Name + ' (' + $base.Architecture + ', ' + $base.Codename + ') - about ' + (Format-Bytes $base.InstalledSizeBytes) + ' installed'
    }

    $logBox = & $find 'DevLog'
    $devLogTargets = New-Object System.Collections.Generic.List[object]
    $devLogTargets.Add($logBox)
    $script:logTargets.Add($logBox)

    $script:devSetStatus = { param([string]$Text)
        $status = & $script:devFind 'DevBuildStatus'
        if ($status) { $status.Text = $Text }
    }

    $btnCheckPrereqs = & $find 'BtnCheckPrereqs'
    $btnCheckPrereqs.Add_Click({
        & $script:devSetStatus 'Checking prerequisites...'
        $ok = $true
        $messages = @()
        if (Get-BundledAria2Directory) {
            $messages += 'aria2: bundled'
        } else {
            $ok = $false
            $messages += 'aria2: NOT found in tools\aria2'
        }
        if (Test-WslReady) {
            $messages += 'WSL (Ubuntu): ready'
        } else {
            $messages += 'WSL (Ubuntu): not ready (needed only for the dynamic build)'
        }
        if ($ok) { & $script:devSetStatus 'Prerequisites OK' } else { & $script:devSetStatus 'Prerequisites missing' }
        foreach ($message in $messages) { Write-AppLog ('[dev] ' + $message) }
    })

    $btnBuildImage = & $find 'BtnBuildImage'
    $btnBuildImage.Add_Click({
        $find = $script:devFind
        $chkRaw = & $find 'ChkDevRawBuild'
        $baseImagePath = $null
        $configPath = $null
        if ($chkRaw.IsChecked) {
            $baseImagePath = (& $find 'TxtDevBaseImage').Text
            $configPath = (& $find 'TxtDevConfig').Text
            if (-not $baseImagePath -or -not (Test-Path $baseImagePath)) {
                & $script:devSetStatus 'Choose a valid base image file.'
                return
            }
            if (-not $configPath -or -not (Test-Path $configPath)) {
                & $script:devSetStatus 'Choose a valid base config file.'
                return
            }
        }
        $arguments = '-WorkspaceDir "' + $script:workspaceDirectory + '" -CacheDir "' + $script:cacheDirectory + '"'
        if ($baseImagePath) {
            $arguments += ' -BaseImagePath "' + $baseImagePath + '" -BaseConfigPath "' + $configPath + '"'
        }
        & $script:devSetStatus 'Building appliance image...'
        $onLine = { param([string]$Line, [string]$Stream) Add-Log ('[dev-build] ' + $Line) }
        $onComplete = {
            param([int]$ExitCode, [string[]]$Output)
            if ($ExitCode -eq 0) {
                & $script:devSetStatus 'Appliance image build finished.'
            } else {
                & $script:devSetStatus 'Appliance image build failed (exit code ' + $ExitCode.ToString() + ').'
            }
        }
        Start-BuildProcess -FilePath $script:buildImageScript -Arguments $arguments -OnLine $onLine -OnComplete $onComplete
    })

    $cmbProfiles = & $find 'CmbDevProfiles'
    $btnRefreshProfiles = & $find 'BtnDevRefreshProfiles'
    $refreshProfiles = {
        $cmbProfiles = & $script:devFind 'CmbDevProfiles'
        $cmbProfiles.Items.Clear()
        foreach ($profilePath in $script:app.ProfilePaths) {
            $cmbProfiles.Items.Add((Get-ProfileKey -ProfilePath $profilePath)) | Out-Null
        }
        if ($cmbProfiles.Items.Count -gt 0) { $cmbProfiles.SelectedIndex = 0 }
    }
    $btnRefreshProfiles.Add_Click($refreshProfiles)
    & $refreshProfiles

    $devContentInfo = & $find 'DevContentInfo'
    $devLibraryHost = & $find 'DevLibraryHost'
    $btnLoadProfile = & $find 'BtnDevLoadProfile'
    $btnLoadProfile.Add_Click({
        $cmbProfiles = & $script:devFind 'CmbDevProfiles'
        $devContentInfo = & $script:devFind 'DevContentInfo'
        $devLibraryHost = & $script:devFind 'DevLibraryHost'
        $selected = $cmbProfiles.SelectedItem
        if (-not $selected) { return }
        $profilePath = $script:app.ProfilePaths | Where-Object { (Get-ProfileKey -ProfilePath $_) -eq $selected } | Select-Object -First 1
        if (-not $profilePath) { return }
        $items = @(Get-ProfileLibraries -ProfilePath $profilePath -Catalog $script:app.Catalog)
        $totals = Get-SelectionTotals -Items $items
        $devContentInfo.Text = (Get-ProfileDisplayName -ProfilePath $profilePath) + ': ' + $items.Count.ToString() + ' libraries, about ' + (Format-Bytes $totals.TotalBytes)
        $devLibraryHost.Children.Clear()
        foreach ($item in $items) {
            $devLibraryHost.Children.Add((New-UiText ($item.Name + ' - ' + (Format-Bytes $item.EstimatedBytes) + ' - ' + $item.SourceUrl) 'MetaText')) | Out-Null
        }
    })

    $cmbDisks = & $find 'CmbDevDisks'
    $btnRefreshDisks = & $find 'BtnDevRefreshDisks'
    $refreshDisks = {
        $cmbDisks = & $script:devFind 'CmbDevDisks'
        $cmbDisks.Items.Clear()
        foreach ($disk in @(Get-SelectableDisks)) {
            $cmbDisks.Items.Add('Disk ' + $disk.DiskNumber.ToString() + ' - ' + $disk.FriendlyName + ' - ' + (Format-Bytes $disk.Size) + ' - ' + $disk.BusType) | Out-Null
        }
        if ($cmbDisks.Items.Count -gt 0) { $cmbDisks.SelectedIndex = 0 }
    }
    $btnRefreshDisks.Add_Click($refreshDisks)
    & $refreshDisks

    $devSdStatus = & $find 'DevSdStatus'
    $btnEstimate = & $find 'BtnDevEstimate'
    $btnEstimate.Add_Click({
        $devSdStatus = & $script:devFind 'DevSdStatus'
        try {
            $profileFile = Resolve-DevEntries
            $estimate = Get-PreflightEstimate -ProfilePath $profileFile -Catalog $script:app.Catalog -BaseManifest $script:app.BaseManifest
            $devSdStatus.Text = 'Estimated required space: ' + (Format-Bytes $estimate.RequiredBytes) + ' (content ' + (Format-Bytes $estimate.ContentBytes) + ' + base ' + (Format-Bytes $estimate.BaseBytes) + ')'
        } catch {
            $devSdStatus.Text = 'Estimate failed: ' + $_.Exception.Message
        }
    })

    $btnWriteImage = & $find 'BtnDevWriteImage'
    $btnWriteImage.Add_Click({
        $find = $script:devFind
        $cmbDisks = & $find 'CmbDevDisks'
        $devSdStatus = & $find 'DevSdStatus'
        $selectedDisk = $cmbDisks.SelectedItem
        if (-not $selectedDisk) {
            $devSdStatus.Text = 'Select a disk first.'
            return
        }
        $diskNumber = [int](([regex]::Match($selectedDisk, 'Disk (\d+)')).Groups[1].Value)
        $chkRawOutput = & $find 'ChkDevRawOutput'
        $imagePath = $null
        $manifestPath = $null
        if ($chkRawOutput.IsChecked) {
            $imagePath = (& $find 'TxtDevImagePath').Text
            $manifestPath = (& $find 'TxtDevManifestPath').Text
            if (-not $imagePath -or -not (Test-Path $imagePath)) {
                $devSdStatus.Text = 'Choose a valid prepared image file.'
                return
            }
        }
        $profileFile = Resolve-DevEntries
        $wifi = New-WifiCredentials
        $configPath = Join-Path $script:workspaceDirectory 'config\dynamic-appliance-config.json'
        Set-Content -Path $configPath -Value (New-ApplianceConfigJsonText -Wifi $wifi) -Encoding UTF8
        $arguments = New-PrebuiltBuildArguments `
            -DiskNumber $diskNumber `
            -ProfilePath $profileFile `
            -DeviceConfigPath $configPath `
            -ContentDir $script:cacheDirectory `
            -WorkspaceDir $script:workspaceDirectory `
            -ReleaseRepo "MikeyMan83/emergency-web-pi" `
            -ContentMode $script:app.ContentMode
        if ($imagePath) {
            $arguments += ' -ImagePath "' + $imagePath + '"'
            if ($manifestPath) { $arguments += ' -ManifestPath "' + $manifestPath + '"' }
        }
        $devSdStatus.Text = 'Writing to disk ' + $diskNumber.ToString() + '...'
        $onLine = { param([string]$Line, [string]$Stream) Add-Log ('[dev-write] ' + $Line) }
        $onComplete = {
            param([int]$ExitCode, [string[]]$Output)
            if ($ExitCode -eq 0) {
                $devSdStatus.Text = 'Write finished.'
            } else {
                $devSdStatus.Text = 'Write failed (exit code ' + $ExitCode.ToString() + ').'
            }
        }
        Start-BuildProcess -FilePath $script:prebuiltScript -Arguments $arguments -OnLine $onLine -OnComplete $onComplete
    })

    $btnDynamicBuild = & $find 'BtnDevDynamicBuild'
    $btnDynamicBuild.Add_Click({
        Invoke-DynamicBuild -Window $script:devWindow -Find $script:devFind -StatusControl (& $script:devFind 'DevSdStatus')
    })

    $txtDevBaseImage = & $find 'TxtDevBaseImage'
    $btnDevBaseImageBrowse = & $find 'BtnDevBaseImageBrowse'
    $btnDevBaseImageBrowse.Add_Click({
        $txtDevBaseImage = & $script:devFind 'TxtDevBaseImage'
        $path = Select-FilePath -Filter 'Raspberry Pi image (*.img;*.img.xz;*.zip)|*.img;*.img.xz;*.zip|All files (*.*)|*.*' -Title 'Select the base image'
        if ($path) { $txtDevBaseImage.Text = $path }
    })
    $txtDevConfig = & $find 'TxtDevConfig'
    $btnDevConfigBrowse = & $find 'BtnDevConfigBrowse'
    $btnDevConfigBrowse.Add_Click({
        $txtDevConfig = & $script:devFind 'TxtDevConfig'
        $path = Select-FilePath -Filter 'JSON config (*.json)|*.json|All files (*.*)|*.*' -Title 'Select the base config'
        if ($path) { $txtDevConfig.Text = $path }
    })
    $txtDevZimDir = & $find 'TxtDevZimDir'
    $btnDevZimDirBrowse = & $find 'BtnDevZimDirBrowse'
    $btnDevZimDirBrowse.Add_Click({
        $txtDevZimDir = & $script:devFind 'TxtDevZimDir'
        $path = Select-FolderPath -Description 'Select the folder with ZIM files'
        if ($path) { $txtDevZimDir.Text = $path }
    })
    $txtDevProfilePath = & $find 'TxtDevProfilePath'
    $btnDevProfileBrowse = & $find 'BtnDevProfileBrowse'
    $btnDevProfileBrowse.Add_Click({
        $txtDevProfilePath = & $script:devFind 'TxtDevProfilePath'
        $path = Select-FilePath -Filter 'Profile (*.txt)|*.txt|All files (*.*)|*.*' -Title 'Select a profile file'
        if ($path) { $txtDevProfilePath.Text = $path }
    })
    $txtDevManifestPath = & $find 'TxtDevManifestPath'
    $btnDevManifestBrowse = & $find 'BtnDevManifestBrowse'
    $btnDevManifestBrowse.Add_Click({
        $txtDevManifestPath = & $script:devFind 'TxtDevManifestPath'
        $path = Select-FilePath -Filter 'Manifest (*.json)|*.json|All files (*.*)|*.*' -Title 'Select the manifest'
        if ($path) { $txtDevManifestPath.Text = $path }
    })

    $btnOpenWorkspace = & $find 'BtnDevOpenWorkspace'
    $btnOpenWorkspace.Add_Click({ Start-Process -FilePath $script:workspaceDirectory -ErrorAction SilentlyContinue })
    $btnOpenLogs = & $find 'BtnDevOpenLogs'
    $btnOpenLogs.Add_Click({ Start-Process -FilePath (Join-Path $script:repoRoot 'logs') -ErrorAction SilentlyContinue })
    $btnAbout = & $find 'BtnDevAbout'
    $btnAbout.Add_Click({
        Show-AppMessage -Kind Info -Title 'About Emergency Web Pi' -Message ('Emergency Web Pi version ' + $script:appVersion + '.' + [Environment]::NewLine + 'Repository: ' + $script:repoRoot)
    })

    $devAdvVersion = & $find 'DevAdvVersion'
    $devAdvVersion.Text = $script:appVersion
    (& $find 'DevAdvRepoRoot').Text = $script:repoRoot
    (& $find 'DevAdvWorkspace').Text = $script:workspaceDirectory
    (& $find 'DevAdvCache').Text = $script:cacheDirectory
    (& $find 'DevAdvBaseManifest').Text = (Join-Path $script:repoRoot 'config\base-image.json')
    (& $find 'DevAdvGeneratedProfiles').Text = (Join-Path $script:workspaceDirectory 'generated-profiles')
    (& $find 'DevAdvLogs').Text = (Join-Path $script:repoRoot 'logs')
    (& $find 'TxtDevReleaseRepo').Text = 'MikeyMan83/emergency-web-pi'

    $btnClose = & $find 'BtnDevClose'
    $btnClose.Add_Click({
        $script:logTargets.Remove((& $script:devFind 'DevLog')) | Out-Null
        $script:devWindow.Close()
    })

    [void]$window.ShowDialog()
    $script:logTargets.Remove($logBox) | Out-Null
}

function Invoke-DynamicBuild {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][scriptblock]$Find,
        [Parameter(Mandatory)]$StatusControl
    )
    if (-not $script:prebuiltFlow -and -not (Test-WslReady)) {
        Show-WslSetupGuidance
        return
    }
    $cmbDisks = & $Find 'CmbDevDisks'
    $selectedDisk = $cmbDisks.SelectedItem
    if (-not $selectedDisk) {
        $StatusControl.Text = 'Select a disk first.'
        return
    }
    $diskNumber = [int](([regex]::Match($selectedDisk, 'Disk (\d+)')).Groups[1].Value)
    $chkRawContent = & $Find 'ChkDevRawContent'
    $profilePath = $null
    $contentDir = $null
    if ($chkRawContent.IsChecked) {
        $profilePath = (& $Find 'TxtDevProfilePath').Text
        $contentDir = (& $Find 'TxtDevCacheDir').Text
        if (-not $profilePath -or -not (Test-Path $profilePath)) {
            $StatusControl.Text = 'Choose a valid profile file.'
            return
        }
    } else {
        $profilePath = Resolve-DevEntries
    }
    $chkRawBuild = & $Find 'ChkDevRawBuild'
    $baseConfigPath = $null
    $baseImagePath = $null
    if ($chkRawBuild.IsChecked) {
        $baseConfigPath = (& $Find 'TxtDevConfig').Text
        $baseImagePath = (& $Find 'TxtDevBaseImage').Text
        if (-not $baseConfigPath -or -not (Test-Path $baseConfigPath)) {
            $StatusControl.Text = 'Choose a valid base config file.'
            return
        }
    }
    $arguments = '-DiskNumber ' + $diskNumber.ToString() + ' -ConfirmDiskNumber ' + $diskNumber.ToString() + ' -Force'
    $arguments += ' -ProfilePath "' + $profilePath + '"'
    if ($contentDir) { $arguments += ' -ContentDir "' + $contentDir + '"' }
    if ($baseConfigPath) { $arguments += ' -BaseConfigPath "' + $baseConfigPath + '"' }
    if ($baseImagePath) { $arguments += ' -BaseImagePath "' + $baseImagePath + '"' }
    $arguments += ' -WorkspaceDir "' + $script:workspaceDirectory + '"'
    $arguments += ' -CacheDir "' + $script:cacheDirectory + '"'
    $arguments += ' -ContentMode ' + $script:app.ContentMode
    $StatusControl.Text = 'Starting the dynamic (WSL) build...'
    $onLine = { param([string]$Line, [string]$Stream) Add-Log ('[dev-dynamic] ' + $Line) }
    $onComplete = {
        param([int]$ExitCode, [string[]]$Output)
        if ($ExitCode -eq 0) {
            $StatusControl.Text = 'Dynamic build finished.'
        } else {
            $StatusControl.Text = 'Dynamic build failed (exit code ' + $ExitCode.ToString() + ').'
        }
    }
    Start-BuildProcess -FilePath $script:dynamicScript -Arguments $arguments -OnLine $onLine -OnComplete $onComplete
}

function Start-EndUserFlow {
    Write-AppLog 'Starting the Emergency Web Pi creator.'
    $script:app.Catalog = Get-ContentCatalog -RepoRoot $script:repoRoot
    $script:app.BaseManifest = Get-PinnedBaseImageInfo -RepoRoot $script:repoRoot
    $script:app.ProfilePaths = @(Get-ChildItem -Path (Join-Path $script:repoRoot 'profiles') -Filter '*.txt' | Sort-Object Name | ForEach-Object { $_.FullName })
    $window = New-CreatorWindow
    Write-AppLog 'Opening the Emergency Web Pi creator.'
    [void]$window.ShowDialog()
}

Start-EndUserFlow
