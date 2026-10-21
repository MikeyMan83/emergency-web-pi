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
