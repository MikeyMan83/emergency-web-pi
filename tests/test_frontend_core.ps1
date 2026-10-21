#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for portable/EmergencyWebPi-Core.ps1 (the shared creator logic).
.DESCRIPTION
    Runs under both Windows PowerShell 5.1 and PowerShell 7 (pwsh) so CI can
    execute it on Linux. Exits non-zero when any assertion fails.
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

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)][AllowNull()]$Expected,
    [Parameter(Mandatory = $true)][AllowNull()]$Actual,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($Expected -eq $Actual) {
    $script:passed += 1
  } else {
    $script:failed += 1
    Write-Output ("FAIL: " + $Name + " (expected [" + $Expected + "], got [" + $Actual + "])")
  }
}

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Contains,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $threw = $false
  try {
    & $Action | Out-Null
  } catch {
    $threw = $true
    if ($Contains -and $_.Exception.Message -notmatch [regex]::Escape($Contains)) {
      $script:failed += 1
      Write-Output ("FAIL: " + $Name + " (wrong error: " + $_.Exception.Message + ")")
      return
    }
  }
  Assert-True $threw $Name
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $repoRoot "portable/EmergencyWebPi-Core.ps1")

# --- Format-Bytes -----------------------------------------------------------
# Expected values use the same culture-aware formatting as the function.
Assert-Equal ("{0:N0} B" -f 512) (Format-Bytes -Bytes 512) "Format-Bytes bytes"
Assert-Equal ("{0:N2} KB" -f (1536 / 1KB)) (Format-Bytes -Bytes 1536) "Format-Bytes kilobytes"
Assert-Equal ("{0:N2} GB" -f (2GB / 1GB)) (Format-Bytes -Bytes 2GB) "Format-Bytes gigabytes"
Assert-Equal ("{0:N2} TB" -f (1.5TB / 1TB)) (Format-Bytes -Bytes 1.5TB) "Format-Bytes terabytes"

# --- Resolve-ZimFileName ----------------------------------------------------
Assert-Equal "wikipedia_en_all_nopic.zim" (Resolve-ZimFileName -Url "https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic.zim") "Resolve-ZimFileName plain url"
Assert-Equal "wikipedia_en_all_nopic.zim" (Resolve-ZimFileName -Url "https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic.zim.torrent") "Resolve-ZimFileName torrent url"

# --- Catalog ----------------------------------------------------------------
$catalog = Get-ContentCatalog -RepoRoot $repoRoot
Assert-Equal 11 @($catalog.PSObject.Properties).Count "catalog has 11 entries"
foreach ($property in $catalog.PSObject.Properties) {
  $item = $property.Value
  Assert-True ($property.Name.EndsWith(".zim")) ("catalog key is a ZIM file: " + $property.Name)
  Assert-True (-not [string]::IsNullOrWhiteSpace($item.name)) ("catalog name present: " + $property.Name)
  Assert-True (-not [string]::IsNullOrWhiteSpace($item.description)) ("catalog description present: " + $property.Name)
  Assert-True ([int64]$item.estimatedBytes -gt 0) ("catalog size positive: " + $property.Name)
  Assert-True ($item.sourceUrl.StartsWith("https://")) ("catalog sourceUrl https: " + $property.Name)
  Assert-True ($item.learnMoreUrl.StartsWith("https://")) ("catalog learnMoreUrl https: " + $property.Name)
}

$known = Get-CatalogItemForUrl -Catalog $catalog -Url "https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic.zim"
Assert-Equal "wikipedia_en_all_nopic.zim" $known.Id "catalog item id"
Assert-Equal "Wikipedia - English" $known.Name "catalog item display name"
Assert-True $known.KnownSize "catalog item known size"
Assert-True ($known.EstimatedBytes -gt 0) "catalog item estimated bytes"

$unknown = Get-CatalogItemForUrl -Catalog $catalog -Url "https://example.com/not-in-catalog.zim"
Assert-True (-not $unknown.KnownSize) "unknown catalog item has unknown size"
Assert-Equal 0 $unknown.EstimatedBytes "unknown catalog item has zero size"

# --- Profiles ---------------------------------------------------------------
$profilesDir = Join-Path $repoRoot "profiles"
$profilePaths = @(Get-ChildItem -Path $profilesDir -Filter "*.txt" | Sort-Object Name | ForEach-Object { $_.FullName })
Assert-Equal 4 $profilePaths.Count "four profiles exist"

$entries = @(Read-ProfileEntries -ProfileFile (Join-Path $profilesDir "medical-survival-zimlist.txt"))
Assert-Equal 11 $entries.Count "medical-survival lists every catalog entry"
foreach ($entry in $entries) {
  Assert-True ($entry.StartsWith("https://")) ("profile entry is a URL: " + $entry)
}

$libraries = @(Get-ProfileLibraries -Catalog $catalog -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt"))
Assert-Equal 11 $libraries.Count "medical-survival resolves 11 libraries"
Assert-True (@($libraries | Where-Object { -not $_.KnownSize }).Count -eq 0) "all medical-survival libraries have known sizes"

$emergency = @(Get-ProfileLibraries -Catalog $catalog -ProfilePath (Join-Path $profilesDir "emergency-medical-zimlist.txt"))
Assert-True ($emergency.Count -lt 11) "emergency-medical is a subset"
Assert-True ($emergency.Count -gt 0) "emergency-medical is not empty"

# --- Profile display metadata ----------------------------------------------
Assert-Equal "Emergency & Medical" (Get-ProfileDisplayName -ProfilePath (Join-Path $profilesDir "emergency-medical-zimlist.txt")) "display name emergency"
Assert-Equal "Essential Web" (Get-ProfileDisplayName -ProfilePath (Join-Path $profilesDir "essential-web-zimlist.txt")) "display name essential"
Assert-Equal "Practical & Repair" (Get-ProfileDisplayName -ProfilePath (Join-Path $profilesDir "practical-repair-zimlist.txt")) "display name practical"
Assert-Equal "Everything - Complete library" (Get-ProfileDisplayName -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt")) "display name everything"
Assert-True ((Get-ProfileDescription -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt")).Length -gt 10) "description is human readable"

$tags = @(Get-ProfileCategoryTags -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt"))
Assert-True ($tags -contains "Medical") "everything tags include Medical"
Assert-True ($tags -contains "Reference") "everything tags include Reference"
Assert-True ($tags -contains "Repair") "everything tags include Repair"
Assert-True ($tags -contains "Q&A") "everything tags include Q&A"
Assert-True ($tags -contains "Disaster readiness") "everything tags include Disaster readiness"
$essentialTags = @(Get-ProfileCategoryTags -ProfilePath (Join-Path $profilesDir "essential-web-zimlist.txt"))
Assert-Equal 1 $essentialTags.Count "essential-web has exactly one tag"
Assert-Equal "Reference" $essentialTags[0] "essential-web tag is Reference"

# --- Profile keys (stable identifiers without the -zimlist suffix) --------------
# The creator sorts, badges and preselects profiles by this key; a mismatch between the
# key used there and the actual file names silently breaks all three.
Assert-Equal "emergency-medical" (Get-ProfileKey -ProfilePath (Join-Path $profilesDir "emergency-medical-zimlist.txt")) "profile key emergency"
Assert-Equal "essential-web" (Get-ProfileKey -ProfilePath (Join-Path $profilesDir "essential-web-zimlist.txt")) "profile key essential"
Assert-Equal "practical-repair" (Get-ProfileKey -ProfilePath (Join-Path $profilesDir "practical-repair-zimlist.txt")) "profile key practical"
Assert-Equal "medical-survival" (Get-ProfileKey -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt")) "profile key everything"
Assert-Equal "medical-survival" (Get-ProfileKey -ProfilePath (Join-Path "some dir" "medical-survival-zimlist.txt")) "profile key strips directories"
Assert-Equal "custom-profile" (Get-ProfileKey -ProfilePath (Join-Path $profilesDir "custom-profile.txt")) "profile key keeps plain names"
$profileKeys = @($profilePaths | ForEach-Object { Get-ProfileKey -ProfilePath $_ })
Assert-Equal 4 @($profileKeys | Sort-Object -Unique).Count "profile keys are unique"
Assert-True ($profileKeys -contains "medical-survival") "profile keys contain the recommended baseline"

# --- Selection totals -------------------------------------------------------
$totals = Get-SelectionTotals -Items $libraries
Assert-Equal 11 $totals.Count "totals count"
Assert-True $totals.KnownSize "totals known size"
Assert-Equal 0 $totals.UnknownCount "totals unknown count"
$mixed = Get-SelectionTotals -Items @($known, $unknown)
Assert-True (-not $mixed.KnownSize) "mixed totals are not fully known"
Assert-Equal 1 $mixed.UnknownCount "mixed totals unknown count"
Assert-Equal $known.EstimatedBytes $mixed.TotalBytes "mixed totals only count known sizes"

# --- Base image and capacity formula ----------------------------------------
$base = Get-PinnedBaseImageInfo -RepoRoot $repoRoot
Assert-Equal "Raspberry Pi OS Lite" $base.name "base image name"
Assert-Equal "arm64" $base.architecture "base image architecture"
Assert-True ([int64]$base.installedSizeBytes -gt 0) "base image installed size"

Assert-Equal (2GB + 8GB) (Get-ApplianceRequiredBytes -BaseBytes 2GB -ContentBytes 0) "required bytes empty content uses 8 GiB minimum"
Assert-Equal (2GB + 8GB) (Get-ApplianceRequiredBytes -BaseBytes 2GB -ContentBytes 6GB) "required bytes small content uses 8 GiB minimum"
Assert-Equal (2GB + 9GB) (Get-ApplianceRequiredBytes -BaseBytes 2GB -ContentBytes 8GB) "required bytes rounds content up with 1 GiB margin"
Assert-Equal (2GB + 11GB) (Get-ApplianceRequiredBytes -BaseBytes 2GB -ContentBytes 10GB) "required bytes 10 GiB content rounds up to 11 GiB partition"

$required = Get-RequiredBytesForLibraries -BaseManifest $base -Items $libraries
Assert-Equal (Get-ApplianceRequiredBytes -BaseBytes ([int64]$base.installedSizeBytes) -ContentBytes $totals.TotalBytes) $required "required bytes for libraries matches formula"

# --- Preflight estimate ------------------------------------------------------
$estimate = Get-PreflightEstimate -BaseManifest $base -Items $libraries
Assert-Equal ([int64]$base.installedSizeBytes) $estimate.BaseBytes "estimate base bytes"
Assert-Equal $totals.TotalBytes $estimate.ContentBytes "estimate content bytes"
Assert-Equal $required $estimate.RequiredBytes "estimate required bytes"

$estimateFromProfile = Get-PreflightEstimate -BaseManifest $base -ProfilePath (Join-Path $profilesDir "medical-survival-zimlist.txt") -Catalog $catalog
Assert-Equal $estimate.RequiredBytes $estimateFromProfile.RequiredBytes "estimate from profile matches estimate from items"

Assert-Throws { Get-PreflightEstimate -BaseManifest $base -Items @($unknown) } "Content catalog is missing a verified size" "estimate rejects unknown sizes"
Assert-Throws { Get-PreflightEstimate -BaseManifest $base -Items @() } "No content selected" "estimate rejects empty selection"

# --- Drive cards -------------------------------------------------------------
$usbDisk = [PSCustomObject]@{ DiskNumber = 1; FriendlyName = "Generic MassStorageClass"; Size = 32GB; BusType = "USB"; DriveLetters = @("E") }
$card = Get-DriveCardInfo -Disk $usbDisk
Assert-Equal "Ready" $card.StatusKind "usb disk ready"
Assert-True $card.Eligible "usb disk eligible"
Assert-True $card.Title.Contains("Generic MassStorageClass") "card title shows model"
Assert-True $card.Title.Contains("GB") "card title shows size"
Assert-True $card.DriveKind.Contains("Removable") "card drive kind removable"
Assert-True $card.Detail.Contains("E") "card detail shows drive letter"

$fixedDisk = [PSCustomObject]@{ DiskNumber = 0; FriendlyName = "NVMe Boot Disk"; Size = 512GB; BusType = "NVMe"; DriveLetters = @("C") }
$fixedCard = Get-DriveCardInfo -Disk $fixedDisk
Assert-Equal "NotRemovable" $fixedCard.StatusKind "fixed disk not removable"
Assert-True (-not $fixedCard.Eligible) "fixed disk not eligible"

$smallCard = Get-DriveCardInfo -Disk $usbDisk -RequiredBytes 64GB
Assert-Equal "TooSmall" $smallCard.StatusKind "small disk too small"
Assert-True (-not $smallCard.Eligible) "small disk not eligible"
Assert-True $smallCard.StatusText.Contains((Format-Bytes -Bytes 64GB)) "too small status mentions requirement"

$fitsCard = Get-DriveCardInfo -Disk $usbDisk -RequiredBytes 16GB
Assert-Equal "Ready" $fitsCard.StatusKind "sufficient disk ready"
Assert-True $fitsCard.Eligible "sufficient disk eligible"
Assert-True $fitsCard.StatusText.Contains("sufficient") "sufficient status text"

$zeroDisk = [PSCustomObject]@{ Number = 2; Model = "Empty Reader"; SizeBytes = 0; BusType = "USB" }
$zeroCard = Get-DriveCardInfo -Disk $zeroDisk
Assert-Equal "Unknown" $zeroCard.StatusKind "zero capacity unknown"
Assert-True (-not $zeroCard.Eligible) "zero capacity not eligible"

# --- Creator stages ----------------------------------------------------------
$prebuiltStages = @(Get-CreatorStages -ContentMode "Prebuilt")
$prebuiltIds = @($prebuiltStages | ForEach-Object { $_.Id })
Assert-Equal "requirements,system,download,write,partition,copy,verify,done" ($prebuiltIds -join ",") "prebuilt stage list"
$firstBootStages = @(Get-CreatorStages -ContentMode "FirstBoot")
$firstBootIds = @($firstBootStages | ForEach-Object { $_.Id })
Assert-Equal "requirements,system,write,partition,verify,done" ($firstBootIds -join ",") "first boot stage list has no download or copy"
foreach ($stage in $prebuiltStages) {
  Assert-True (-not [string]::IsNullOrWhiteSpace($stage.Label)) ("stage has label: " + $stage.Id)
  Assert-True (-not [string]::IsNullOrWhiteSpace($stage.Detail)) ("stage has detail: " + $stage.Id)
}

# --- Writer line mapping -----------------------------------------------------
$stageCases = @(
  @{ Line = "Downloading base image asset: ewp-base-0.4.0.img.gz"; Stage = "system" }
  @{ Line = "Unpacking base image ..."; Stage = "system" }
  @{ Line = "Base image verified."; Stage = "system" }
  @{ Line = "Downloading: wikipedia_en_all_nopic.zim"; Stage = "download" }
  @{ Line = "Using cached: wikipedia_en_all_nopic.zim"; Stage = "download" }
  @{ Line = "Writing appliance image to disk #1 ..."; Stage = "write" }
  @{ Line = "Creating ZIMDATA (exFAT) partition ..."; Stage = "partition" }
  @{ Line = "Copying: wikipedia_en_all_nopic.zim"; Stage = "copy" }
  @{ Line = "Flushing to the card ..."; Stage = "verify" }
  @{ Line = "Prebuilt SD build complete"; Stage = "done" }
  @{ Line = "Checking administrator access."; Stage = "requirements" }
  @{ Line = "Checking target SD card (disk #1)."; Stage = "requirements" }
  @{ Line = "Looking up the base image release."; Stage = "system" }
  @{ Line = "Downloading base image manifest."; Stage = "system" }
  @{ Line = "Downloading base image asset: ewp-base-0.4.0.img.gz.001"; Stage = "system" }
  @{ Line = "Base image download: 12.3 of 45.6 MB (27%)"; Stage = "system" }
  @{ Line = "Using cached base image asset: ewp-base-0.4.0.img.gz.001"; Stage = "system" }
  @{ Line = "Verifying base image download (SHA-256)."; Stage = "system" }
  @{ Line = "Verifying unpacked base image (SHA-256)."; Stage = "system" }
  @{ Line = "Unpacking base image: 1.0 of 2.0 GB (50%)"; Stage = "system" }
  @{ Line = "Writing appliance image: 42%"; Stage = "write" }
)
foreach ($case in $stageCases) {
  Assert-Equal $case.Stage (Get-StageForWriterLine -Line $case.Line) ("stage for line: " + $case.Line)
}
Assert-Equal $null (Get-StageForWriterLine -Line "Some unrelated output") "unrelated line maps to null stage"
Assert-Equal $null (Get-StageForWriterLine -Line "") "empty line maps to null stage"
Assert-Equal $null (Get-StageForWriterLine -Line "Checked: SD card accepted - Generic MassStorageClass, 29.8 GB, USB bus.") "checked-only line does not advance the stage"

# --- Download percent --------------------------------------------------------
Assert-Equal 42 (Get-DownloadPercentForLine -Line "[#a1b2c3 840MiB/2.0GiB(42%) CN:5 DL:8.5MiB]") "aria2 percent parsed"
Assert-Equal 0 (Get-DownloadPercentForLine -Line "[#a1b2c3 0MiB/2.0GiB(0%) CN:1 DL:0b]") "aria2 zero percent parsed"
Assert-Equal 73 (Get-DownloadPercentForLine -Line "[#9ff24d 1.8MiB/2.5MiB(73%) CN:1 DL:3.7MiB]") "aria2 KiB/MiB percent parsed"
Assert-Equal $null (Get-DownloadPercentForLine -Line "Downloading: file.zim") "non-aria2 line has null percent"
Assert-Equal $null (Get-DownloadPercentForLine -Line "Base image download: 12.3 of 45.6 MB (27%)") "base image progress is not content percent"
Assert-Equal $null (Get-DownloadPercentForLine -Line "Writing appliance image: 42%") "write progress is not content percent"
Assert-Equal $null (Get-DownloadPercentForLine -Line "Unpacking base image: 1.0 of 2.0 GB (50%)") "unpack progress is not content percent"

# --- Write percent -----------------------------------------------------------
Assert-Equal 42 (Get-WritePercentForLine -Line "Writing appliance image: 42%") "write percent parsed"
Assert-Equal 100 (Get-WritePercentForLine -Line "Writing appliance image: 100%") "write percent 100 parsed"
Assert-Equal 0 (Get-WritePercentForLine -Line "Writing appliance image: 0%") "write percent 0 parsed"
Assert-Equal $null (Get-WritePercentForLine -Line "Writing appliance image to disk #1 ...") "write stage entry has no percent"
Assert-Equal $null (Get-WritePercentForLine -Line "Some unrelated output") "unrelated line has no write percent"
Assert-Equal $null (Get-WritePercentForLine -Line "") "empty line has no write percent"

# --- Writer status text ------------------------------------------------------
Assert-Equal "Checking administrator access." (Get-WriterStatusTextForLine -Line "Checking administrator access.") "specific requirement shown"
Assert-Equal "Checking target SD card (disk #1)." (Get-WriterStatusTextForLine -Line "Checking target SD card (disk #1).") "specific disk check shown"
Assert-Equal "Looking up the base image release." (Get-WriterStatusTextForLine -Line "Looking up the base image release.") "lookup status"
Assert-Equal "Downloading base image manifest." (Get-WriterStatusTextForLine -Line "Downloading base image manifest.") "manifest status"
Assert-Equal "Downloading system image - ewp-base-0.4.0.img.gz.001" (Get-WriterStatusTextForLine -Line "Downloading base image asset: ewp-base-0.4.0.img.gz.001") "asset download status"
Assert-Equal "Downloading system image - 12.3 of 45.6 MB (27%)" (Get-WriterStatusTextForLine -Line "Base image download: 12.3 of 45.6 MB (27%)") "asset progress status"
Assert-Equal "Using cached system image - ewp-base-0.4.0.img.gz.001" (Get-WriterStatusTextForLine -Line "Using cached base image asset: ewp-base-0.4.0.img.gz.001") "cached asset status"
Assert-Equal "Verifying base image download (SHA-256)." (Get-WriterStatusTextForLine -Line "Verifying base image download (SHA-256).") "verify download status"
Assert-Equal "Verifying unpacked base image (SHA-256)." (Get-WriterStatusTextForLine -Line "Verifying unpacked base image (SHA-256).") "verify unpacked status"
Assert-Equal "Unpacking base image: 1.0 of 2.0 GB (50%)" (Get-WriterStatusTextForLine -Line "Unpacking base image: 1.0 of 2.0 GB (50%)") "unpack progress status"
Assert-Equal "System files are ready." (Get-WriterStatusTextForLine -Line "Base image verified.") "verified status"
Assert-Equal "Downloading content - wikipedia_en_all_nopic.zim" (Get-WriterStatusTextForLine -Line "Downloading: wikipedia_en_all_nopic.zim") "content download status"
Assert-Equal "Using cached content - wikipedia_en_all_nopic.zim" (Get-WriterStatusTextForLine -Line "Using cached: wikipedia_en_all_nopic.zim") "cached content status"
Assert-Equal "Copying wikipedia_en_all_nopic.zim (840.5 MB)" (Get-WriterStatusTextForLine -Line "Copying: wikipedia_en_all_nopic.zim (840.5 MB)") "copy status"
Assert-Equal $null (Get-WriterStatusTextForLine -Line "Checked: SD card accepted - Generic MassStorageClass, 29.8 GB, USB bus.") "checked-only line has no status override"
Assert-Equal $null (Get-WriterStatusTextForLine -Line "Some unrelated output") "unrelated line has no status override"
Assert-Equal $null (Get-WriterStatusTextForLine -Line "") "empty line has no status override"

# --- Cancellation safety -----------------------------------------------------
Assert-True (Test-WriterCancellationSafe -StageId "requirements") "requirements cancellable"
Assert-True (Test-WriterCancellationSafe -StageId "system") "system cancellable"
Assert-True (Test-WriterCancellationSafe -StageId "download") "download cancellable"
Assert-True (-not (Test-WriterCancellationSafe -StageId "write")) "write not cancellable"
Assert-True (-not (Test-WriterCancellationSafe -StageId "partition")) "partition not cancellable"
Assert-True (-not (Test-WriterCancellationSafe -StageId "copy")) "copy not cancellable"
Assert-True (-not (Test-WriterCancellationSafe -StageId "verify")) "verify not cancellable"

# --- Argument quoting ----------------------------------------------------------
Assert-Equal '"C:\path with spaces\profile.txt"' (Quote-Arg -Value "C:\path with spaces\profile.txt") "Quote-Arg wraps in quotes"
Assert-Equal '"a""b"' (Quote-Arg -Value 'a"b') "Quote-Arg doubles embedded quotes"

# --- Frozen writer argument contract -----------------------------------------
$buildArgs = New-PrebuiltBuildArguments `
  -DiskNumber 3 `
  -ProfilePath "C:\ws\creator-profile.txt" `
  -DeviceConfigPath "C:\ws\config\dynamic-appliance-config.json" `
  -ContentDir "C:\cache" `
  -WorkspaceDir "C:\ws" `
  -ReleaseRepo "MikeyMan83/emergency-web-pi" `
  -ContentMode "Prebuilt"
Assert-True ($buildArgs -is [string]) "build arguments are a single string"
foreach ($needle in @("-DiskNumber 3", "-ConfirmDiskNumber 3", "-Force", '-Profile "C:\ws\creator-profile.txt"', '-DeviceConfigPath "C:\ws\config\dynamic-appliance-config.json"', '-ContentDir "C:\cache"', '-WorkspaceDir "C:\ws"', '-ReleaseRepo "MikeyMan83/emergency-web-pi"', "-ContentMode Prebuilt")) {
  Assert-True ($buildArgs.Contains($needle)) ("build arguments contain " + $needle)
}
Assert-True (-not $buildArgs.Contains("-ImagePath")) "no image path without override"
Assert-True (-not $buildArgs.Contains("-ApSsid")) "credentials travel via the device config"
$buildArgsWithImage = New-PrebuiltBuildArguments `
  -DiskNumber 3 `
  -ProfilePath "C:\ws\creator-profile.txt" `
  -DeviceConfigPath "C:\ws\config\dynamic-appliance-config.json" `
  -ContentDir "C:\cache" `
  -WorkspaceDir "C:\ws" `
  -ReleaseRepo "MikeyMan83/emergency-web-pi" `
  -ContentMode "FirstBoot" `
  -ImagePathOverride "D:\images\base.img"
Assert-True ($buildArgsWithImage.Contains('-ImagePath "D:\images\base.img"')) "image override appended"
Assert-True ($buildArgsWithImage.Contains("-ContentMode FirstBoot")) "first boot mode passed through"

# --- Wi-Fi credentials ---------------------------------------------------------
for ($i = 0; $i -lt 5; $i++) {
  $wifi = New-WifiCredentials
  Assert-True ($wifi.Ssid -match "^EmergencyWebPi-[A-Za-z0-9]{4}$") ("ssid format: " + $wifi.Ssid)
  Assert-Equal 12 $wifi.Password.Length "password length"
  Assert-True ($wifi.Password -match "^[A-Za-z0-9]{12}$") "password charset"
  Assert-True ($wifi.Password -match "^[\x20-\x7e]{8,63}$") "password satisfies Pi rules"
}
$wifiA = New-WifiCredentials
$wifiB = New-WifiCredentials
Assert-True ($wifiA.Ssid -ne $wifiB.Ssid -or $wifiA.Password -ne $wifiB.Password) "credentials are random"

# --- Appliance config JSON -----------------------------------------------------
$configJson = New-ApplianceConfigJsonText -Wifi $wifiA
$config = $configJson | ConvertFrom-Json
Assert-Equal 1 $config.schemaVersion "config schema version"
Assert-Equal $wifiA.Ssid $config.ap.ssid "config ssid"
Assert-Equal $wifiA.Password $config.ap.password "config password"

# --- Wi-Fi label HTML ------------------------------------------------------------
$label = New-WifiLabelHtml -Ssid $wifiA.Ssid -Password $wifiA.Password -Version "0.4.0"
Assert-True ($label.Contains($wifiA.Ssid)) "label contains ssid"
Assert-True ($label.Contains($wifiA.Password)) "label contains password"
Assert-True ($label.Contains("0.4.0")) "label contains version"
Assert-True ($label.Contains("Safely eject the SD card")) "label contains first-boot steps"
$labelNoVersion = New-WifiLabelHtml -Ssid "ssid" -Password "password"
Assert-True (-not $labelNoVersion.Contains("Emergency Web Pi version")) "label omits version line when not given"

# --- Frontend static-call scan (regression guard for bare Type::Method calls) -----
foreach ($frontendFile in @("portable/EmergencyWebPi.ps1", "portable/EmergencyWebPi-Core.ps1")) {
  $tokens = $null
  $parseErrors = $null
  $frontendAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $frontendFile), [ref]$tokens, [ref]$parseErrors)
  Assert-Equal 0 $parseErrors.Count ("frontend parses without errors: " + $frontendFile)
  $bareStaticCalls = @($frontendAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -match '^[A-Za-z_][A-Za-z0-9_]*::'
  }, $true))
  Assert-Equal 0 $bareStaticCalls.Count ("no bare Type::Method command calls (must use [Full.Type.Name]::Method): " + $frontendFile)
}

# --- Read-only automatic variable scan (regression guard for $host-style locals) ----
# $Host, $PID, $HOME, $ShellId and $ExecutionContext are read-only automatic variables;
# a local assigned one of those names throws "Cannot overwrite variable ..." at runtime.
foreach ($frontendFile in @("portable/EmergencyWebPi.ps1", "portable/EmergencyWebPi-Core.ps1")) {
  $frontendSource = Get-Content (Join-Path $repoRoot $frontendFile) -Raw
  $readonlyAssignments = @([regex]::Matches($frontendSource, '(?i)\$(host|pid|home|shellid|executioncontext)\b\s*=[^=]'))
  $readonlyText = ($readonlyAssignments | ForEach-Object { $_.Value }) -join ", "
  Assert-Equal 0 $readonlyAssignments.Count ("no assignments to read-only automatic variables (host/pid/home/shellid/executioncontext) in " + $frontendFile + $(if ($readonlyText) { " -- found: " + $readonlyText } else { "" }))

  # "& $sb.Invoke()" invokes the scriptblock and then tries to run its OUTPUT as a
  # command; with no output that throws "The expression after '&' ... was not valid".
  $invokeMisuse = @([regex]::Matches($frontendSource, '& \$[A-Za-z_][A-Za-z0-9_]*\.Invoke\(\)'))
  $invokeText = ($invokeMisuse | ForEach-Object { $_.Value }) -join ", "
  Assert-Equal 0 $invokeMisuse.Count ("no '& `$sb.Invoke()' misuse (must be '& `$sb') in " + $frontendFile + $(if ($invokeText) { " -- found: " + $invokeText } else { "" }))
}

# --- Delegate handler scope scan (regression guard for event-handler closures) -----
# .NET-delegate-invoked handlers (Add_Click/Add_Checked/...) do NOT see locals of the
# function that registered them; only $script:/$global: variables, handler-local
# assignments, parameters, and automatic variables are visible at runtime.
$automaticVariables = @(
  "args", "this", "true", "false", "null", "PSItem", "_", "MyInvocation", "PSBoundParameters",
  "PSScriptRoot", "PWD", "Error", "input", "Matches", "foreach", "switch", "LASTEXITCODE",
  "host", "profile", "PSVersionTable", "NestedPromptLevel", "PID", "PSCulture", "PSUICulture",
  "WhatIfPreference", "ConfirmPreference", "DebugPreference", "VerbosePreference",
  "WarningPreference", "InformationPreference", "ErrorActionPreference", "ProgressPreference",
  "OutputEncoding", "IsWindows", "IsLinux", "IsMacOS", "ExecutionContext", "ShellId", "ConsoleFileName"
)

function Get-HandlerDefinedNames {
  param([System.Management.Automation.Language.ScriptBlockExpressionAst]$Block)
  $defined = @{}
  $allBlocks = @($Block)
  foreach ($nested in $Block.FindAll({ param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
    $allBlocks += $nested
  }
  foreach ($handlerBlock in $allBlocks) {
    if ($handlerBlock.ScriptBlock.ParamBlock) {
      foreach ($parameter in $handlerBlock.ScriptBlock.ParamBlock.Parameters) {
        $defined[$parameter.Name.Extent.Text.TrimStart('$')] = $true
      }
    }
  }
  $assignments = $Block.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
  foreach ($assignment in $assignments) {
    $targets = $assignment.Left.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    foreach ($target in $targets) { $defined[$target.Extent.Text.TrimStart('$')] = $true }
  }
  $loops = $Block.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)
  foreach ($loop in $loops) {
    if ($loop.Variable) { $defined[$loop.Variable.Extent.Text.TrimStart('$')] = $true }
  }
  return $defined
}

function Get-HandlerScopeViolations {
  param(
    [System.Management.Automation.Language.ScriptBlockExpressionAst]$Handler,
    [string]$Context
  )
  $found = @()
  $defined = Get-HandlerDefinedNames -Block $Handler
  $variables = $Handler.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
  foreach ($variable in $variables) {
    $full = $variable.Extent.Text.TrimStart('$')
    if ($full -match '^(script|global):') { continue }
    if ($full -ne $variable.VariablePath.UserPath) {
      $found += ("line " + $variable.Extent.StartLineNumber + ": scoped reference `$" + $full + " in " + $Context)
      continue
    }
    if ($defined.ContainsKey($full)) { continue }
    if ($automaticVariables -contains $full) { continue }
    $found += ("line " + $variable.Extent.StartLineNumber + ": `$" + $full + " is not visible inside the delegate handler " + $Context)
  }
  return $found
}

foreach ($frontendFile in @("portable/EmergencyWebPi.ps1", "portable/EmergencyWebPi-Core.ps1")) {
  $tokens = $null
  $parseErrors = $null
  $frontendAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $frontendFile), [ref]$tokens, [ref]$parseErrors)
  $handlerCount = 0
  $violations = @()
  $eventCalls = @($frontendAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
  foreach ($call in $eventCalls) {
    $methodName = $call.Member.Value
    if ($methodName -notmatch '^(?i)add_') { continue }
    $enclosingFunction = $call.Parent
    while ($enclosingFunction -and -not ($enclosingFunction -is [System.Management.Automation.Language.FunctionDefinitionAst])) {
      $enclosingFunction = $enclosingFunction.Parent
    }
    $functionName = if ($enclosingFunction) { $enclosingFunction.Name } else { "<top-level>" }
    foreach ($argument in $call.Arguments) {
      $context = ($functionName + "." + $methodName + " (line " + $call.Extent.StartLineNumber + ")")
      if ($argument -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $handlerCount += 1
        $violations += @(Get-HandlerScopeViolations -Handler $argument -Context $context)
      } elseif ($argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $variableName = $argument.Extent.Text.TrimStart('$')
        if ($variableName -match ':') { continue }
        if (-not $enclosingFunction) { continue }
        $resolved = $false
        $assignments = $enclosingFunction.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
        foreach ($assignment in $assignments) {
          $targets = $assignment.Left.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
          $isTarget = $false
          foreach ($target in $targets) { if ($target.Extent.Text.TrimStart('$') -eq $variableName) { $isTarget = $true } }
          if (-not $isTarget) { continue }
          $blocks = $assignment.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
          foreach ($block in $blocks) {
            $handlerCount += 1
            $resolved = $true
            $violations += @(Get-HandlerScopeViolations -Handler $block -Context ($context + " [via `$" + $variableName + "]"))
          }
        }
        if (-not $resolved) {
          $violations += ("line " + $call.Extent.StartLineNumber + ": `$" + $variableName + " passed to " + $context + " has no scriptblock assignment")
        }
      }
    }
  }
  if ($frontendFile -eq "portable/EmergencyWebPi.ps1") {
    Assert-True ($handlerCount -ge 40) ("delegate handler scan found handlers (found " + $handlerCount + ")")
  }
  $violationText = $violations -join " | "
  Assert-True ($violations.Count -eq 0) ("delegate handlers reference only visible variables in " + $frontendFile + $(if ($violationText) { " -- VIOLATIONS: " + $violationText } else { "" }))
}

# --- WPF type-name scan (regression guard for nonexistent System.Windows types) ----
# "New-Object System.Windows.Controls.Hyperlink" throws "Cannot find type" at runtime
# because the WPF hyperlink lives in System.Windows.Documents, not Controls. A typo'd
# WPF type name only fails when its code path runs, so every System.Windows* type the
# frontend references (New-Object argument or [Full.Type.Name] literal) must be in this
# allowlist of names verified against the real .NET Framework WPF assemblies.
$knownWpfTypeNames = @(
  "System.Windows.Controls.Border",
  "System.Windows.Controls.Canvas",
  "System.Windows.Controls.CheckBox",
  "System.Windows.Controls.DockPanel",
  "System.Windows.Controls.Primitives.ToggleButton",
  "System.Windows.Controls.StackPanel",
  "System.Windows.Controls.TextBlock",
  "System.Windows.Controls.WrapPanel",
  "System.Windows.CornerRadius",
  "System.Windows.Documents.Hyperlink",
  "System.Windows.Forms.DialogResult",
  "System.Windows.Forms.FolderBrowserDialog",
  "System.Windows.Markup.XamlReader",
  "System.Windows.Media.ColorConverter",
  "System.Windows.Media.SolidColorBrush",
  "System.Windows.MessageBox",
  "System.Windows.Thickness",
  "System.Windows.Threading.DispatcherTimer"
)

function Get-FrontendWpfTypeNames {
  param([string]$Source)
  $names = @{}
  foreach ($match in [regex]::Matches($Source, 'New-Object\s+([A-Za-z_][A-Za-z0-9_.]*)')) {
    $names[$match.Groups[1].Value] = $true
  }
  foreach ($match in [regex]::Matches($Source, '\[((?:System\.Windows(?:\.[A-Za-z_][A-Za-z0-9_]*)+))\]')) {
    $names[$match.Groups[1].Value] = $true
  }
  return @($names.Keys | Where-Object { $_ -like "System.Windows*" } | Sort-Object)
}

foreach ($frontendFile in @("portable/EmergencyWebPi.ps1", "portable/EmergencyWebPi-Core.ps1")) {
  $frontendSource = Get-Content (Join-Path $repoRoot $frontendFile) -Raw
  $wpfTypeNames = @(Get-FrontendWpfTypeNames -Source $frontendSource)
  $unknown = @($wpfTypeNames | Where-Object { $knownWpfTypeNames -notcontains $_ })
  $unknownText = $unknown -join ", "
  Assert-Equal 0 $unknown.Count ("only known WPF type names are referenced in " + $frontendFile + $(if ($unknownText) { " -- unknown: " + $unknownText } else { "" }))
  if ($frontendFile -eq "portable/EmergencyWebPi.ps1") {
    Assert-True ($wpfTypeNames.Count -ge 15) ("WPF type-name scan found references in " + $frontendFile + " (found " + $wpfTypeNames.Count + ")")
  }
}

# negative test: the extraction itself must surface the historical typo
$plantedSource = "`$x = New-Object System.Windows.Controls.Hyperlink`r`n`$y = [System.Windows.Documents.Hyperlink]::Parse"
$plantedNames = @(Get-FrontendWpfTypeNames -Source $plantedSource)
Assert-True (($plantedNames -contains "System.Windows.Controls.Hyperlink") -and ($plantedNames -contains "System.Windows.Documents.Hyperlink")) "WPF type-name scan extracts New-Object and [Type] references"

# --- Style target-type scan (regression guard for Style/TargetType mismatches) ------
# Assigning a Style whose XAML TargetType does not match the element type throws
# "TargetType X does not match the type of element Y" at runtime (this is how the
# LinkText style, TargetType=Hyperlink, ended up applied to a TextBlock). Every literal
# FindResource('Key') style application must reference an existing XAML style whose
# TargetType matches the element type assigned to the variable (simple-name compare).
$xamlStyles = @{}
foreach ($xamlFile in @("portable/ui/MainWindow.xaml", "portable/ui/DeveloperTools.xaml", "portable/ui/ConfirmErase.xaml")) {
  $xamlSource = Get-Content (Join-Path $repoRoot $xamlFile) -Raw
  foreach ($match in [regex]::Matches($xamlSource, '<Style\b[^>]*>')) {
    $keyMatch = [regex]::Match($match.Value, 'x:Key="([^"]+)"')
    $targetMatch = [regex]::Match($match.Value, 'TargetType="([^"]+)"')
    if ($keyMatch.Success -and $targetMatch.Success) {
      $xamlStyles[$keyMatch.Groups[1].Value] = $targetMatch.Groups[1].Value
    }
  }
}
Assert-True ($xamlStyles.Count -ge 20) ("XAML style map collected (found " + $xamlStyles.Count + ")")

function Get-StyleTargetViolations {
  param([string]$FrontendSource, [hashtable]$XamlStyles)
  $violations = @()
  $styleApps = @([regex]::Matches($FrontendSource, '\$([A-Za-z_][A-Za-z0-9_]*)\.Style\s*=\s*\$script:window\.FindResource\(''([^'']+)''\)'))
  foreach ($app in $styleApps) {
    $varName = $app.Groups[1].Value
    $styleKey = $app.Groups[2].Value
    if (-not $XamlStyles.ContainsKey($styleKey)) {
      $violations += ('$' + $varName + ' uses unknown style key ' + $styleKey)
      continue
    }
    $targetSimple = $XamlStyles[$styleKey] -replace '^.*\.', ''
    $assignments = @([regex]::Matches($FrontendSource, '\$' + $varName + '\b\s*=\s*New-Object\s+([A-Za-z_][A-Za-z0-9_.]*)'))
    $simpleNames = @($assignments | ForEach-Object { $_.Groups[1].Value -replace '^.*\.', '' })
    if ($simpleNames.Count -eq 0) {
      $violations += ('$' + $varName + ' receives style ' + $styleKey + ' but has no New-Object assignment')
      continue
    }
    if ($simpleNames -notcontains $targetSimple) {
      $violations += ('$' + $varName + ' receives style ' + $styleKey + ' (TargetType ' + $targetSimple + ') but is created as: ' + ($simpleNames -join ', '))
    }
  }
  return $violations
}

foreach ($frontendFile in @("portable/EmergencyWebPi.ps1", "portable/EmergencyWebPi-Core.ps1")) {
  $frontendSource = Get-Content (Join-Path $repoRoot $frontendFile) -Raw
  $styleViolations = @(Get-StyleTargetViolations -FrontendSource $frontendSource -XamlStyles $xamlStyles)
  $styleText = $styleViolations -join " | "
  Assert-Equal 0 $styleViolations.Count ("style applications match XAML TargetType in " + $frontendFile + $(if ($styleText) { " -- VIOLATIONS: " + $styleText } else { "" }))
}

# negative test: the scan must flag a TextBlock receiving the Hyperlink-targeted style
$plantedStyleSource = '$link = New-Object System.Windows.Controls.TextBlock' + "`n" + '$link.Style = $script:window.FindResource(''LinkText'')'
$plantedViolations = @(Get-StyleTargetViolations -FrontendSource $plantedStyleSource -XamlStyles $xamlStyles)
Assert-True ($plantedViolations.Count -ge 1) "style target-type scan flags TargetType mismatches"

# --- Stage weights and whole-workflow progress --------------------------------
# The weights are the whole-workflow progress contract: they must sum to 100 for
# every mode, and the base percent of a stage is the sum of the weights of the
# stages before it, so entering a stage never moves the bar backwards.
$prebuiltWeights = Get-CreatorStageWeights -ContentMode "Prebuilt"
Assert-Equal 5 ([int]$prebuiltWeights.requirements) "prebuilt requirements weight"
Assert-Equal 25 ([int]$prebuiltWeights.system) "prebuilt system weight"
Assert-Equal 35 ([int]$prebuiltWeights.download) "prebuilt download weight"
Assert-Equal 20 ([int]$prebuiltWeights.write) "prebuilt write weight"
Assert-Equal 5 ([int]$prebuiltWeights.partition) "prebuilt partition weight"
Assert-Equal 8 ([int]$prebuiltWeights.copy) "prebuilt copy weight"
Assert-Equal 2 ([int]$prebuiltWeights.verify) "prebuilt verify weight"
Assert-Equal 0 ([int]$prebuiltWeights.done) "prebuilt done carries no weight"
$prebuiltWeightSum = 0
foreach ($stage in @(Get-CreatorStages -ContentMode "Prebuilt")) { $prebuiltWeightSum += [int]$prebuiltWeights.($stage.Id) }
Assert-Equal 100 $prebuiltWeightSum "prebuilt weights sum to 100"

$firstBootWeights = Get-CreatorStageWeights -ContentMode "FirstBoot"
Assert-Equal 5 ([int]$firstBootWeights.requirements) "first boot requirements weight"
Assert-Equal 55 ([int]$firstBootWeights.system) "first boot system weight"
Assert-Equal 25 ([int]$firstBootWeights.write) "first boot write weight"
Assert-Equal 10 ([int]$firstBootWeights.partition) "first boot partition weight"
Assert-Equal 5 ([int]$firstBootWeights.verify) "first boot verify weight"
$firstBootWeightSum = 0
foreach ($stage in @(Get-CreatorStages -ContentMode "FirstBoot")) { $firstBootWeightSum += [int]$firstBootWeights.($stage.Id) }
Assert-Equal 100 $firstBootWeightSum "first boot weights sum to 100"

Assert-Equal 0 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "requirements") "prebuilt requirements base is 0"
Assert-Equal 5 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "system") "prebuilt system base is 5"
Assert-Equal 30 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "download") "prebuilt download base is 30"
Assert-Equal 65 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "write") "prebuilt write base is 65"
Assert-Equal 85 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "partition") "prebuilt partition base is 85"
Assert-Equal 90 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "copy") "prebuilt copy base is 90"
Assert-Equal 98 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "verify") "prebuilt verify base is 98"
Assert-Equal 100 (Get-CreatorStageBasePercent -ContentMode "Prebuilt" -StageId "done") "prebuilt done base is 100"
Assert-Equal 5 (Get-CreatorStageBasePercent -ContentMode "FirstBoot" -StageId "system") "first boot system base is 5"
Assert-Equal 60 (Get-CreatorStageBasePercent -ContentMode "FirstBoot" -StageId "write") "first boot write base is 60"
Assert-Equal 95 (Get-CreatorStageBasePercent -ContentMode "FirstBoot" -StageId "verify") "first boot verify base is 95"

# Overall percent = stage base + stage weight * stage percent / 100.
Assert-Equal 17 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "system" -StagePercent 50) "overall percent mid-system"
Assert-Equal 65 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "download" -StagePercent 100) "overall percent at download end"
Assert-Equal 94 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "copy" -StagePercent 50) "overall percent mid-copy"
Assert-Equal 100 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "verify" -StagePercent 100) "overall percent at verify end"
Assert-Equal 100 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "done" -StagePercent 0) "overall percent for done is 100"
Assert-Equal 60 (Get-CreatorOverallPercent -ContentMode "FirstBoot" -StageId "write" -StagePercent 0) "overall percent at write start"
Assert-Equal 30 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "system" -StagePercent 250) "overall percent clamps stage percent"
Assert-Equal 5 (Get-CreatorOverallPercent -ContentMode "Prebuilt" -StageId "system" -StagePercent -10) "overall percent clamps negative stage percent"

# --- System (base image) progress lines ----------------------------------------
Assert-Equal 42 (Get-SystemPercentForLine -Line "System files: 42%") "system percent parsed"
Assert-Equal 0 (Get-SystemPercentForLine -Line "System files: 0%") "system percent zero parsed"
Assert-Equal 100 (Get-SystemPercentForLine -Line "System files: 100%") "system percent 100 parsed"
Assert-Equal $null (Get-SystemPercentForLine -Line "Downloading: file.zim") "content line has no system percent"
Assert-Equal $null (Get-SystemPercentForLine -Line "System files: soon") "non-numeric system line has no percent"
Assert-Equal $null (Get-SystemPercentForLine -Line "") "empty line has no system percent"

# --- Weighted download and item stage progress ---------------------------------
Assert-Equal 5 (Get-DownloadStagePercent -CompletedWeight 0 -CurrentWeight 10 -CurrentPercent 50 -TotalWeight 100) "download stage percent mid-item"
Assert-Equal 50 (Get-DownloadStagePercent -CompletedWeight 50 -CurrentWeight 0 -CurrentPercent 0 -TotalWeight 100) "download stage percent between items"
Assert-Equal 100 (Get-DownloadStagePercent -CompletedWeight 100 -CurrentWeight 0 -CurrentPercent 0 -TotalWeight 100) "download stage percent complete"
Assert-Equal 0 (Get-DownloadStagePercent -CompletedWeight 0 -CurrentWeight 0 -CurrentPercent 0 -TotalWeight 0) "download stage percent with no items"
Assert-Equal 75 (Get-ItemStagePercent -CompletedCount 3 -TotalCount 4) "item stage percent counts copies"
Assert-Equal 0 (Get-ItemStagePercent -CompletedCount 0 -TotalCount 0) "item stage percent with no items"
Assert-Equal 100 (Get-ItemStagePercent -CompletedCount 4 -TotalCount 4) "item stage percent complete"

# --- Writer line mapping for the image acquisition and copy stages -------------
$stageCases2 = @(
  @{ Line = "System files: 42%"; Stage = "system" }
  @{ Line = "Checking available disk space."; Stage = "system" }
  @{ Line = "Verifying cached base image asset (SHA-256)."; Stage = "system" }
  @{ Line = "Cached base image asset verified."; Stage = "system" }
  @{ Line = "Cached base image asset failed verification: ewp-base-0.4.1.img.gz"; Stage = "system" }
  @{ Line = "Removing incomplete base image download: ewp-base-0.4.1.img.gz.partial"; Stage = "system" }
  @{ Line = "Preparing to download selected content."; Stage = "download" }
  @{ Line = "Content download complete."; Stage = "download" }
  @{ Line = "Copied: wikipedia_en_all_nopic.zim"; Stage = "copy" }
)
foreach ($case in $stageCases2) {
  Assert-Equal $case.Stage (Get-StageForWriterLine -Line $case.Line) ("stage for line: " + $case.Line)
}

# --- Status text for the image acquisition and copy stages ---------------------
Assert-Equal "Preparing system files - 42%" (Get-WriterStatusTextForLine -Line "System files: 42%") "system progress status"
Assert-Equal "Checking available disk space." (Get-WriterStatusTextForLine -Line "Checking available disk space.") "disk space status"
Assert-Equal "Verifying cached base image asset (SHA-256)." (Get-WriterStatusTextForLine -Line "Verifying cached base image asset (SHA-256).") "cache verify status"
Assert-Equal "Cached system image verified." (Get-WriterStatusTextForLine -Line "Cached base image asset verified.") "cache verified status"
Assert-Equal "Cached system image failed verification; downloading it again." (Get-WriterStatusTextForLine -Line "Cached base image asset failed verification: ewp-base-0.4.1.img.gz") "cache failed status"
Assert-Equal "Removing incomplete base image download: ewp-base-0.4.1.img.gz.partial" (Get-WriterStatusTextForLine -Line "Removing incomplete base image download: ewp-base-0.4.1.img.gz.partial") "stale partial status"
Assert-Equal "Preparing to download the selected libraries." (Get-WriterStatusTextForLine -Line "Preparing to download selected content.") "content prep status"
Assert-Equal "Selected content is ready." (Get-WriterStatusTextForLine -Line "Content download complete.") "content complete status"
Assert-Equal "Copied wikipedia_en_all_nopic.zim" (Get-WriterStatusTextForLine -Line "Copied: wikipedia_en_all_nopic.zim") "copied status"

# --- Manifest override in the frozen writer argument contract ------------------
$buildArgsWithManifest = New-PrebuiltBuildArguments `
  -DiskNumber 3 `
  -ProfilePath "C:\ws\creator-profile.txt" `
  -DeviceConfigPath "C:\ws\config\dynamic-appliance-config.json" `
  -ContentDir "C:\cache" `
  -WorkspaceDir "C:\ws" `
  -ReleaseRepo "MikeyMan83/emergency-web-pi" `
  -ContentMode "Prebuilt" `
  -ImagePathOverride "D:\images\ewp-base-0.4.1.img.gz" `
  -ManifestPathOverride "D:\images\ewp-base-0.4.1.img.manifest.json"
Assert-True ($buildArgsWithManifest.Contains('-ImagePath "D:\images\ewp-base-0.4.1.img.gz"')) "image override appended with manifest"
Assert-True ($buildArgsWithManifest.Contains('-ManifestPath "D:\images\ewp-base-0.4.1.img.manifest.json"')) "manifest override appended"
$buildArgsNoManifest = New-PrebuiltBuildArguments `
  -DiskNumber 3 `
  -ProfilePath "C:\ws\creator-profile.txt" `
  -DeviceConfigPath "C:\ws\config\dynamic-appliance-config.json" `
  -ContentDir "C:\cache" `
  -WorkspaceDir "C:\ws" `
  -ReleaseRepo "MikeyMan83/emergency-web-pi" `
  -ContentMode "Prebuilt" `
  -ImagePathOverride "D:\images\ewp-base-0.4.1.img.gz"
Assert-True (-not $buildArgsNoManifest.Contains("-ManifestPath")) "no manifest path without override"

# --- Summary ---------------------------------------------------------------------
Write-Output ("")
Write-Output ("Core module tests: " + $script:passed + " passed, " + $script:failed + " failed.")
if ($script:failed -gt 0) {
  exit 1
}
exit 0
