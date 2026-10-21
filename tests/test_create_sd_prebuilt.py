import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WRITER = (REPO_ROOT / "scripts" / "create-sd-prebuilt.ps1").read_text(encoding="utf-8")
FRONTEND = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")


class PrebuiltWriterTests(unittest.TestCase):
    def test_no_wsl_dependency(self) -> None:
        self.assertNotIn("wsl", WRITER.lower())

    def test_safety_invariants(self) -> None:
        self.assertIn("-ConfirmDiskNumber", WRITER.replace("$ConfirmDiskNumber", "-ConfirmDiskNumber"))
        self.assertIn("Refusing to write", WRITER)
        self.assertIn("zero capacity", WRITER)
        self.assertIn("-AllowFixedDisk", WRITER)
        self.assertIn("Require-Admin", WRITER)

    def test_manifest_and_hash_validation(self) -> None:
        self.assertIn("schemaVersion -ne 3", WRITER)
        self.assertIn("windows-writer", WRITER)
        self.assertIn("device-config-on-first-boot", WRITER)
        self.assertIn("image.sha256", WRITER)

    def test_partition_and_completion_contract(self) -> None:
        self.assertIn("New-Partition", WRITER)
        self.assertIn("-FileSystem exFAT -NewFileSystemLabel ZIMDATA", WRITER)
        for name in ("content-manifest.json", "device-config.json", ".content-complete", ".content-install-pending"):
            self.assertIn(name, WRITER)
        # The completion marker is written after every content file.
        self.assertGreater(WRITER.rindex(".content-complete"), WRITER.index("Copy-Item -Path (Join-Path $resolvedCache"))

    def test_content_is_downloaded_before_the_card_is_erased(self) -> None:
        self.assertLess(WRITER.index("Invoke-AriaDownload -Aria"), WRITER.index("Write-ImageToDisk -ImagePath $rawImage"))

    def test_credential_rules_match_the_pi(self) -> None:
        self.assertIn("8,63", WRITER)
        self.assertIn("[A-Z]{2}", WRITER)

    def test_progress_is_reported_for_each_phase(self) -> None:
        for needle in (
            '"Checking administrator access."',
            '"Checking target SD card',
            '"Checking content profile."',
            '"Checking Wi-Fi configuration."',
            '"Looking up the base image release."',
            '"Downloading base image manifest."',
            '"Verifying base image download (SHA-256)."',
            '"Verifying unpacked base image (SHA-256)."',
            '"Unpacking base image: "',
            '"Writing appliance image: $percent%"',
            '"Writing appliance image: 100%"',
            '"Base image download"',
        ):
            self.assertIn(needle, WRITER)

    def test_network_calls_are_bounded(self) -> None:
        self.assertIn("-TimeoutSec 120", WRITER)
        self.assertIn("$request.Timeout = 120000", WRITER)
        self.assertIn("$request.ReadWriteTimeout = 300000", WRITER)

    def test_requirement_checks_run_before_any_disk_write(self) -> None:
        self.assertLess(WRITER.index("Write-Host \"Checking administrator access.\""), WRITER.index("Get-TargetDisk -Number $DiskNumber"))
        self.assertLess(WRITER.index("Get-TargetDisk -Number $DiskNumber"), WRITER.index("Write-ImageToDisk -ImagePath $rawImage"))
        self.assertLess(WRITER.index("Invoke-AriaDownload -Aria"), WRITER.index("Write-ImageToDisk -ImagePath $rawImage"))

    def test_downloads_are_atomic(self) -> None:
        # Assets download to a .partial file and are renamed only after the
        # full body is on disk, so an interrupted download can never be
        # mistaken for a verified cached image.
        self.assertIn("$partialPath = $Destination + \".partial\"", WRITER)
        self.assertIn("Move-Item $partialPath $Destination", WRITER)
        self.assertIn("Remove-Item $partialPath -Force -ErrorAction SilentlyContinue", WRITER)

    def test_stale_partial_downloads_are_removed(self) -> None:
        self.assertIn('Get-ChildItem -Path $TargetDir -Filter "*.partial"', WRITER)
        self.assertIn("Removing incomplete base image download: ", WRITER)

    def test_cached_assets_are_hash_verified(self) -> None:
        # A cached asset is reused only after its SHA-256 matches the manifest;
        # a mismatching cache is deleted and downloaded again.
        self.assertIn("Verifying cached base image asset (SHA-256).", WRITER)
        self.assertIn("Cached base image asset verified.", WRITER)
        self.assertIn("Cached base image asset failed verification: $name", WRITER)
        self.assertIn("function Get-ExpectedAssetSha256", WRITER)
        self.assertIn("Get-ExpectedAssetSha256 -Manifest $manifest -Name $name", WRITER)
        # Already-verified cached assets are not hashed twice during unpack.
        self.assertIn("-SkipHashPaths $verifiedImagePaths", WRITER)

    def test_free_space_is_checked_before_downloading(self) -> None:
        self.assertIn("function Get-DriveFreeBytes", WRITER)
        self.assertIn("Not enough free space on the workspace drive", WRITER)
        # In the download path the check runs before any asset download starts.
        download_fn = WRITER.split("function Download-BaseImageAssets", 1)[1].split("function Expand-BaseImage", 1)[0]
        self.assertLess(download_fn.index("Checking available disk space."), download_fn.index("Save-ReleaseAsset -Asset $info.Asset"))
        # In the raw-image path the check runs before hashing and unpacking.
        self.assertLess(WRITER.index("Checking available disk space."), WRITER.index("Verifying base image download (SHA-256)."))

    def test_system_progress_is_reported(self) -> None:
        self.assertIn('"System files: 0%"', WRITER)
        self.assertIn('"System files: 100%"', WRITER)
        self.assertIn("function Initialize-SystemProgress", WRITER)
        self.assertIn("function Add-SystemProgress", WRITER)
        self.assertIn("Complete-SystemProgress", WRITER)
        # Hashing, joining and gunzipping all feed the system progress tracker.
        self.assertIn("Get-FileSha256WithProgress -Path $path -TrackSystemProgress", WRITER)
        self.assertIn("Get-FileSha256WithProgress -Path $rawImage -TrackSystemProgress", WRITER)

    def test_content_copy_progress_is_reported(self) -> None:
        self.assertIn('"Preparing to download selected content."', WRITER)
        self.assertIn('"Content download complete."', WRITER)
        self.assertIn('"Copied: $($item.name)"', WRITER)

    def test_sd_card_free_space_is_checked_before_writing(self) -> None:
        self.assertIn("Not enough free space on the SD card", WRITER)
        self.assertLess(WRITER.index("Not enough free space on the SD card"), WRITER.index("Write-ImageToDisk -ImagePath $rawImage"))

    def test_manifest_requires_distribution_hashes(self) -> None:
        self.assertIn("Manifest is missing name, sizeBytes, or sha256 for an image part.", WRITER)
        self.assertIn("Manifest is missing distribution.file, sizeBytes, or sha256.", WRITER)

    def test_base_image_unavailable_error_points_to_the_ewp_base_files(self) -> None:
        self.assertIn("BASE_IMAGE_UNAVAILABLE", WRITER)
        self.assertIn("Download the ewp-base files manually and pass -ImagePath.", WRITER)


class CreatorUsesPrebuiltWriterTests(unittest.TestCase):
    def test_end_user_flow_is_wsl_free(self) -> None:
        flow = FRONTEND.split("function Start-EndUserFlow", 1)[1].split("\nStart-EndUserFlow", 1)[0]
        self.assertNotIn("Test-WslReady", flow)
        self.assertNotIn("create-sd-dynamic", flow)
        build = FRONTEND.split("function Start-CreatorBuild", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("$script:prebuiltFlow = $true", build)
        self.assertIn("$scriptToRun = $prebuiltScript", build)

    def test_developer_path_keeps_wsl_guard(self) -> None:
        self.assertIn("if (-not $script:prebuiltFlow -and -not (Test-WslReady))", FRONTEND)

    def test_creator_runs_prebuilt_script_and_keeps_label(self) -> None:
        self.assertIn("$scriptToRun = $prebuiltScript", FRONTEND)
        self.assertIn("EmergencyWebPi-WiFi-Label.html", FRONTEND)
        self.assertIn("BASE_IMAGE_UNAVAILABLE", FRONTEND)


if __name__ == "__main__":
    unittest.main()
