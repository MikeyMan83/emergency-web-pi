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


class WizardUsesPrebuiltWriterTests(unittest.TestCase):
    def test_end_user_flow_is_wsl_free(self) -> None:
        flow = FRONTEND.split("function Start-EndUserFlow", 1)[1].split("$btnWizard.Add_Click", 1)[0]
        self.assertNotIn("Test-WslReady", flow)
        self.assertIn("$script:prebuiltFlow = $true", flow)

    def test_developer_path_keeps_wsl_guard(self) -> None:
        self.assertIn("if (-not $script:prebuiltFlow -and -not (Test-WslReady))", FRONTEND)

    def test_wizard_runs_prebuilt_script_and_keeps_label(self) -> None:
        self.assertIn("$scriptToRun = $prebuiltScript", FRONTEND)
        self.assertIn("EmergencyWebPi-WiFi-Label.html", FRONTEND)
        self.assertIn("BASE_IMAGE_UNAVAILABLE", FRONTEND)


if __name__ == "__main__":
    unittest.main()
