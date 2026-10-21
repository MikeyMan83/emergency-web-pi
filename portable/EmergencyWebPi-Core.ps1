# Emergency Web Pi - shared creator logic.
# This module is side-effect free when dot-sourced: it defines functions only.
# The WPF frontend (portable/EmergencyWebPi.ps1) and the test suites dot-source it.

function Format-Bytes {
  param([double]$Bytes)

  if ($Bytes -lt 1KB) { return "{0:N0} B" -f $Bytes }
  if ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
  if ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
  if ($Bytes -lt 1TB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
  return "{0:N2} TB" -f ($Bytes / 1TB)
}

function Resolve-ZimFileName {
  param([Parameter(Mandatory = $true)][string]$Url)

  $name = [System.IO.Path]::GetFileName($Url)
  if ($name.EndsWith(".torrent", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $name.Substring(0, $name.Length - 8)
  }
  return $name
}

function Get-ContentCatalog {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $catalogPath = Join-Path $RepoRoot "config/content-catalog.json"
  if (-not (Test-Path $catalogPath -PathType Leaf)) {
    throw "Content catalog not found: $catalogPath"
  }
  try {
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
  } catch {
    throw "Content catalog is not valid JSON: $($_.Exception.Message)"
  }
  if ($null -eq $catalog -or @($catalog.PSObject.Properties).Count -eq 0) {
    throw "Content catalog is empty: $catalogPath"
  }
  return $catalog
}

function Get-CatalogItemForUrl {
  param(
    [Parameter(Mandatory = $true)]$Catalog,
    [Parameter(Mandatory = $true)][string]$Url
  )

  $fileName = Resolve-ZimFileName -Url $Url
  $metadata = $Catalog.PSObject.Properties[$fileName].Value
  if ($null -eq $metadata) {
    return [PSCustomObject]@{
      Id = $fileName
      Name = $fileName
      Description = "Offline library content"
      EstimatedBytes = [int64]0
      SourceUrl = $Url
      LearnMoreUrl = "https://kiwix.org/en/catalog/"
      KnownSize = $false
    }
  }

  $size = [int64]$metadata.estimatedBytes
  return [PSCustomObject]@{
    Id = $fileName
    Name = [string]$metadata.name
    Description = [string]$metadata.description
    EstimatedBytes = $size
    SourceUrl = [string]$metadata.sourceUrl
    LearnMoreUrl = [string]$metadata.learnMoreUrl
    KnownSize = ($size -gt 0)
  }
}

function Read-ProfileEntries {
  param([Parameter(Mandatory = $true)][string]$ProfileFile)

  if (-not (Test-Path $ProfileFile -PathType Leaf)) {
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

function Get-ProfileLibraries {
  param(
    [Parameter(Mandatory = $true)]$Catalog,
    [Parameter(Mandatory = $true)][string]$ProfilePath
  )

  $libraries = @()
  foreach ($url in Read-ProfileEntries -ProfileFile $ProfilePath) {
    $libraries += ,(Get-CatalogItemForUrl -Catalog $Catalog -Url $url)
  }
  return $libraries
}

function Get-ProfileKey {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)

  # Stable profile identifier: the file name without extension and without the
  # "-zimlist" suffix (e.g. "profiles/medical-survival-zimlist.txt" -> "medical-survival").
  return ([System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)) -replace '-zimlist$', ''
}

function Get-ProfileDisplayName {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)

  switch ([System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)) {
    "emergency-medical-zimlist" { return "Emergency & Medical" }
    "essential-web-zimlist" { return "Essential Web" }
    "practical-repair-zimlist" { return "Practical & Repair" }
    "medical-survival-zimlist" { return "Everything - Complete library" }
    default { return [System.IO.Path]::GetFileNameWithoutExtension($ProfilePath) }
  }
}

function Get-ProfileDescription {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)

  switch ([System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)) {
    "emergency-medical-zimlist" { return "First aid, emergency medicine, disaster response, and recovery guidance." }
    "essential-web-zimlist" { return "English and Dutch Wikipedia for broad everyday reference." }
    "practical-repair-zimlist" { return "Repair manuals, DIY, mechanics, woodworking, and Raspberry Pi help." }
    "medical-survival-zimlist" { return "All available emergency, medical, reference, repair, and practical knowledge libraries." }
    default { return "Offline library collection." }
  }
}

function Get-ProfileCategoryTags {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)

  # Category labels are derived from the libraries the profile actually contains.
  $tags = New-Object System.Collections.Generic.List[string]
  foreach ($entry in Read-ProfileEntries -ProfileFile $ProfilePath) {
    $name = (Resolve-ZimFileName -Url $entry).ToLowerInvariant()
    if ($name -match "wikipedia") { if (-not $tags.Contains("Reference")) { $tags.Add("Reference") } ; continue }
    if ($name -match "mdwiki|wikem") { if (-not $tags.Contains("Medical")) { $tags.Add("Medical") } ; continue }
    if ($name -match "trueprepper|post-disaster") { if (-not $tags.Contains("Disaster readiness")) { $tags.Add("Disaster readiness") } ; continue }
    if ($name -match "ifixit") { if (-not $tags.Contains("Repair")) { $tags.Add("Repair") } ; continue }
    if ($name -match "stackexchange") { if (-not $tags.Contains("Q&A")) { $tags.Add("Q&A") } ; continue }
  }
  return $tags.ToArray()
}

function Get-SelectionTotals {
  param([Parameter(Mandatory = $true)]$Items)

  [int64]$bytes = 0
  [int64]$unknownCount = 0
  [int]$count = 0
  foreach ($item in $Items) {
    $count += 1
    if ($item.KnownSize) {
      $bytes += [int64]$item.EstimatedBytes
    } else {
      $unknownCount += 1
    }
  }
  return [PSCustomObject]@{
    Count = $count
    TotalBytes = $bytes
    Bytes = $bytes
    UnknownCount = $unknownCount
    KnownSize = ($unknownCount -eq 0)
    Estimable = ($unknownCount -eq 0)
  }
}

function Get-PinnedBaseImageInfo {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $manifestPath = Join-Path $RepoRoot "config/base-image.json"
  if (-not (Test-Path $manifestPath -PathType Leaf)) {
    throw "Pinned base-image manifest not found: $manifestPath"
  }
  try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  } catch {
    throw "Unable to read pinned Raspberry Pi OS base-image manifest: $($_.Exception.Message)"
  }
  if ([string]::IsNullOrWhiteSpace($manifest.name) -or [int64]$manifest.installedSizeBytes -le 0) {
    throw "Pinned base-image manifest is incomplete."
  }
  return $manifest
}

function Get-ApplianceRequiredBytes {
  param(
    [Parameter(Mandatory = $true)][int64]$BaseBytes,
    [Parameter(Mandatory = $true)][int64]$ContentBytes
  )

  [int64]$oneGiB = 1GB
  [int64]$minimumZimPartitionBytes = 8GB
  [int64]$zimPartitionBytes = [Math]::Max(
    $minimumZimPartitionBytes,
    [Math]::Ceiling(($ContentBytes + $oneGiB) / $oneGiB) * $oneGiB
  )

  return $BaseBytes + $zimPartitionBytes
}

function Get-RequiredBytesForLibraries {
  param(
    [Parameter(Mandatory = $true)]$BaseManifest,
    [Parameter(Mandatory = $true)]$Items
  )

  $totals = Get-SelectionTotals -Items $Items
  return Get-ApplianceRequiredBytes -BaseBytes ([int64]$BaseManifest.installedSizeBytes) -ContentBytes $totals.TotalBytes
}

function Get-DriveCardInfo {
  param(
    [Parameter(Mandatory = $true)]$Disk,
    [int64]$RequiredBytes = 0
  )

  # Accepts a Get-Disk object (DiskNumber/FriendlyName/Size/BusType) or a
  # test double with Number/Model/SizeBytes/DriveLetters properties.
  $number = 0
  if ($Disk.PSObject.Properties["DiskNumber"]) { $number = [int]$Disk.DiskNumber }
  elseif ($Disk.PSObject.Properties["Number"]) { $number = [int]$Disk.Number }

  $model = ""
  if ($Disk.PSObject.Properties["FriendlyName"]) { $model = [string]$Disk.FriendlyName }
  elseif ($Disk.PSObject.Properties["Model"]) { $model = [string]$Disk.Model }

  $size = [int64]0
  if ($Disk.PSObject.Properties["Size"]) { $size = [int64]$Disk.Size }
  elseif ($Disk.PSObject.Properties["SizeBytes"]) { $size = [int64]$Disk.SizeBytes }

  $bus = ""
  if ($Disk.PSObject.Properties["BusType"]) { $bus = [string]$Disk.BusType }

  $letters = @()
  if ($Disk.PSObject.Properties["DriveLetters"]) { $letters = @($Disk.DriveLetters) }

  $isRemovable = ($bus -eq "USB" -or $bus -eq "SD")
  $hasCapacity = ($size -gt 0)
  $fits = ($RequiredBytes -le 0 -or $size -ge $RequiredBytes)
  $eligible = ($isRemovable -and $hasCapacity -and $fits)

  $sizeText = Format-Bytes -Bytes $size
  if ([string]::IsNullOrWhiteSpace($model)) {
    $title = "Disk $number - $sizeText"
  } else {
    $title = "$model - $sizeText"
  }

  if ($isRemovable) {
    $driveKind = "Removable drive ($bus)"
  } elseif ([string]::IsNullOrWhiteSpace($bus)) {
    $driveKind = "Drive (unknown bus)"
  } else {
    $driveKind = "Drive ($bus)"
  }

  $detail = ""
  if ($letters.Count -gt 0) {
    $detail = "Drive letter(s): " + ($letters -join ", ")
  }

  $statusKind = "Ready"
  $statusText = "Ready"
  if (-not $isRemovable) {
    $statusKind = "NotRemovable"
    $statusText = "Not removable - Emergency Web Pi can only write to USB/SD card readers"
  } elseif (-not $hasCapacity) {
    $statusKind = "Unknown"
    $statusText = "Capacity could not be determined"
  } elseif (-not $fits) {
    $statusKind = "TooSmall"
    $statusText = "Too small - needs at least $(Format-Bytes -Bytes $RequiredBytes) for the selected content"
  } elseif ($RequiredBytes -gt 0) {
    $statusText = "Capacity sufficient for the selected content"
  }

  return [PSCustomObject]@{
    Number = $number
    Model = $model
    SizeBytes = $size
    SizeText = $sizeText
    BusType = $bus
    DriveLetters = ($letters -join ", ")
    IsRemovable = $isRemovable
    Eligible = $eligible
    Title = $title
    DriveKind = $driveKind
    Detail = $detail
    StatusKind = $statusKind
    StatusText = $statusText
  }
}

function Get-PreflightEstimate {
  param(
    [Parameter(Mandatory = $true)]$BaseManifest,
    [object[]]$Items,
    [string]$ProfilePath = "",
    $Catalog = $null
  )

  # Estimates come from the bundled catalog only; no per-library network
  # requests are made here.
  if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    if ($null -eq $Catalog) {
      throw "Catalog is required to estimate a profile file."
    }
    $Items = @(Get-ProfileLibraries -Catalog $Catalog -ProfilePath $ProfilePath)
  }
  if ($null -eq $Items -or @($Items).Count -eq 0) {
    throw "No content selected for the estimate."
  }

  [int64]$contentBytes = 0
  foreach ($item in @($Items)) {
    [int64]$size = [int64]$item.EstimatedBytes
    if ($size -le 0) {
      throw "Content catalog is missing a verified size for: $($item.Id)"
    }
    $contentBytes += $size
  }

  [int64]$baseBytes = [int64]$BaseManifest.installedSizeBytes
  if ($baseBytes -le 0) {
    throw "Base image size is unknown; cannot estimate the required SD capacity."
  }

  return [PSCustomObject]@{
    BaseBytes = $baseBytes
    ContentBytes = $contentBytes
    RequiredBytes = Get-ApplianceRequiredBytes -BaseBytes $baseBytes -ContentBytes $contentBytes
  }
}

function Get-CreatorStages {
  param([Parameter(Mandatory = $true)][ValidateSet("FirstBoot", "Prebuilt")][string]$ContentMode)

  # Only stages that actually occur in the selected workflow are displayed.
  $prebuilt = ($ContentMode -eq "Prebuilt")
  $stages = @(
    [PSCustomObject]@{ Id = "requirements"; Label = "Checking requirements"; Detail = "Administrator access, SD card, and configuration" }
    [PSCustomObject]@{ Id = "system"; Label = "Preparing system files"; Detail = "Downloading and verifying the Raspberry Pi OS image" }
  )
  if ($prebuilt) {
    $stages += [PSCustomObject]@{ Id = "download"; Label = "Downloading selected content"; Detail = "Downloading the offline libraries to this PC" }
  }
  $stages += [PSCustomObject]@{ Id = "write"; Label = "Writing the appliance to the SD card"; Detail = "Erasing the card and writing the verified system image" }
  $stages += [PSCustomObject]@{ Id = "partition"; Label = "Preparing the content partition"; Detail = "Creating the ZIMDATA partition on the card" }
  if ($prebuilt) {
    $stages += [PSCustomObject]@{ Id = "copy"; Label = "Copying your offline library to the card"; Detail = "Copying the downloaded libraries onto the card" }
  }
  $stages += [PSCustomObject]@{ Id = "verify"; Label = "Verifying the result"; Detail = "Flushing and checking the finished card" }
  $stages += [PSCustomObject]@{ Id = "done"; Label = "Finished"; Detail = "Your Emergency Web Pi is ready" }
  return $stages
}

function Get-StageForWriterLine {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

  $text = $Line.Trim()
  if ($text.Length -eq 0) { return $null }

  if ($text -match "^Downloading base image asset") { return "system" }
  if ($text -match "^Unpacking base image") { return "system" }
  if ($text -match "^Base image verified") { return "system" }
  if ($text -match "^Downloading:") { return "download" }
  if ($text -match "^Using cached:") { return "download" }
  if ($text -match "^Writing appliance image to disk") { return "write" }
  if ($text -match "^Creating ZIMDATA") { return "partition" }
  if ($text -match "^Copying:") { return "copy" }
  if ($text -match "^Flushing to the card") { return "verify" }
  if ($text -match "^Prebuilt SD build complete") { return "done" }
  return $null
}

function Get-DownloadPercentForLine {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

  # aria2c progress lines look like: [#a1b2c3 12MiB/2.0GiB(0%) CN:5 DL:8.5MiB]
  if ($Line -match "\((\d+)%\)") {
    return [int]$Matches[1]
  }
  return $null
}

function Test-WriterCancellationSafe {
  param([Parameter(Mandatory = $true)][string]$StageId)

  # Cancellation is only offered before the destructive write begins.
  return ($StageId -eq "requirements" -or $StageId -eq "system" -or $StageId -eq "download")
}

function Quote-Arg {
  param([Parameter(Mandatory = $true)][string]$Value)

  return '"' + $Value.Replace('"', '""') + '"'
}

function New-PrebuiltBuildArguments {
  param(
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [Parameter(Mandatory = $true)][string]$DeviceConfigPath,
    [Parameter(Mandatory = $true)][string]$ContentDir,
    [Parameter(Mandatory = $true)][string]$WorkspaceDir,
    [Parameter(Mandatory = $true)][string]$ReleaseRepo,
    [Parameter(Mandatory = $true)][ValidateSet("FirstBoot", "Prebuilt")][string]$ContentMode,
    [string]$ImagePathOverride = ""
  )

  # Frozen writer contract: scripts/create-sd-prebuilt.ps1 with bounded arguments.
  $parts = @(
    "-DiskNumber", $DiskNumber,
    "-ConfirmDiskNumber", $DiskNumber,
    "-Force",
    "-Profile", (Quote-Arg -Value $ProfilePath),
    "-ContentDir", (Quote-Arg -Value $ContentDir),
    "-WorkspaceDir", (Quote-Arg -Value $WorkspaceDir),
    "-ReleaseRepo", (Quote-Arg -Value $ReleaseRepo),
    "-DeviceConfigPath", (Quote-Arg -Value $DeviceConfigPath),
    "-ContentMode", $ContentMode
  )
  if (-not [string]::IsNullOrWhiteSpace($ImagePathOverride)) {
    $parts += @("-ImagePath", (Quote-Arg -Value $ImagePathOverride))
  }
  return ($parts -join " ")
}

function New-WifiCredentials {
  $wifiAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $pick = {
      param([int]$Length)
      $bytes = New-Object byte[] $Length
      $rng.GetBytes($bytes)
      $chars = for ($i = 0; $i -lt $Length; $i++) { $wifiAlphabet[$bytes[$i] % $wifiAlphabet.Length] }
      return (-join $chars)
    }
    $ssid = "EmergencyWebPi-" + (& $pick 4)
    $password = (& $pick 12)
  } finally {
    $rng.Dispose()
  }
  return [PSCustomObject]@{ Ssid = $ssid; Password = $password }
}

function New-ApplianceConfigJsonText {
  param([Parameter(Mandatory = $true)]$Wifi)

  # Same shape scripts/create-sd-prebuilt.ps1 writes for -ApSsid/-ApPassword:
  # { schemaVersion: 1, ap: { ssid, password } }, consumed by scripts/device_config.py on the Pi.
  return ([ordered]@{
    schemaVersion = 1
    ap = [ordered]@{
      ssid = [string]$Wifi.Ssid
      password = [string]$Wifi.Password
    }
  } | ConvertTo-Json -Depth 5)
}

function New-WifiLabelHtml {
  param(
    [Parameter(Mandatory = $true)][string]$Ssid,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$Version = ""
  )

  $versionLine = ""
  if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $versionLine = '    <p class="hint">Emergency Web Pi version ' + $Version + '</p>' + "`n"
  }

  return @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Emergency Web Pi - Wi-Fi Label</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 40px; color: #1f2a37; }
  .card { border: 3px dashed #0b5cab; border-radius: 14px; padding: 28px 36px; max-width: 560px; }
  h1 { font-size: 26px; margin: 0 0 6px; }
  p.lead { margin: 0 0 18px; color: #4b5563; }
  .row { font-size: 20px; margin: 10px 0; }
  .row .value { font-weight: bold; letter-spacing: 1px; }
  ol { font-size: 15px; color: #374151; margin: 18px 0 0; padding-left: 22px; }
  ol li { margin: 6px 0; }
  p.hint { font-size: 14px; color: #6b7280; margin-top: 18px; }
</style>
</head>
<body>
  <div class="card">
    <h1>Emergency Web Pi</h1>
    <p class="lead">Offline emergency library - insert the SD card in the Raspberry Pi and power it on.</p>
$versionLine    <div class="row">Wi-Fi name: <span class="value">$Ssid</span></div>
    <div class="row">Wi-Fi password: <span class="value">$Password</span></div>
    <ol>
      <li>Safely eject the SD card from this PC.</li>
      <li>Insert the SD card into the Raspberry Pi and power it on.</li>
      <li>Connect a phone or laptop to the emergency Wi-Fi network above.</li>
      <li>Open any website in a browser; the Emergency Web Pi status page appears automatically.</li>
      <li>Wait until the library says it is ready, then click <strong>Open Library</strong>.</li>
    </ol>
    <p class="hint">Print this label and keep it with the SD card. Anyone who connects to this Wi-Fi can open the library.</p>
  </div>
</body>
</html>
"@
}
