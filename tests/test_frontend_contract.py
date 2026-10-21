import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FRONTEND = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
CORE = (REPO_ROOT / "portable" / "EmergencyWebPi-Core.ps1").read_text(encoding="utf-8")
MAIN_XAML = (REPO_ROOT / "portable" / "ui" / "MainWindow.xaml").read_text(encoding="utf-8")
BLOB = FRONTEND + "\n" + CORE
WRITER = (REPO_ROOT / "scripts" / "create-sd-prebuilt.ps1").read_text(encoding="utf-8")


def function_body(source: str, name: str) -> str:
    match = re.search(r"^function %s\b[^{]*\{" % re.escape(name), source, re.MULTILINE)
    assert match, f"function {name} not found"
    depth = 1
    pos = match.end()
    while depth and pos < len(source):
        char = source[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        pos += 1
    return source[match.end():pos]


class FrontendContractTests(unittest.TestCase):
    def test_startup_opens_the_creator_directly(self):
        body = function_body(FRONTEND, "Start-EndUserFlow")
        self.assertIn("New-CreatorWindow", body)
        self.assertIn("ShowDialog", body)
        self.assertIn("Write-AppLog 'Opening the Emergency Web Pi creator.'", body)
        self.assertNotIn("PerformClick", body)
        self.assertTrue(FRONTEND.rstrip().endswith("Start-EndUserFlow"))

    def test_creator_runs_the_prebuilt_writer(self):
        body = function_body(FRONTEND, "Start-CreatorBuild")
        self.assertIn("$scriptToRun = $prebuiltScript", body)
        self.assertIn("$script:prebuiltFlow = $true", body)
        self.assertIn("New-PrebuiltBuildArguments", body)
        self.assertIn("Start-BuildProcess", body)
        self.assertIn("create-sd-dynamic", FRONTEND)  # referenced only by the developer path
        self.assertNotIn("create-sd-dynamic", body)

    def test_destructive_write_revalidates_the_disk_before_starting(self):
        body = function_body(FRONTEND, "Invoke-ReviewConfirmed")
        self.assertLess(body.index("Test-SelectedDiskStillValid"), body.index("ConfirmErase.xaml"))
        self.assertLess(body.index("ConfirmErase.xaml"), body.index("Start-CreatorBuild"))
        self.assertIn("BtnConfirmErase", body)
        # The disk is revalidated once more after the user confirms.
        confirm_index = body.index("Start-CreatorBuild")
        self.assertEqual(2, body.count("Test-SelectedDiskStillValid"))
        self.assertLess(body.rindex("Test-SelectedDiskStillValid"), confirm_index)

    def test_progress_maps_real_writer_output_to_stages(self):
        body = function_body(FRONTEND, "Start-CreatorBuild")
        self.assertIn("Invoke-BuildLine", body)
        self.assertIn("Build-StageList", body)
        self.assertIn("Set-CurrentStage", body)
        line_handler = function_body(FRONTEND, "Invoke-BuildLine")
        self.assertIn("Get-StageForWriterLine", line_handler)
        self.assertIn("Get-DownloadPercentForLine", line_handler)
        self.assertIn("Get-WritePercentForLine", line_handler)
        self.assertIn("Get-WriterStatusTextForLine", line_handler)
        self.assertIn("Get-CreatorStages", CORE)
        for stage_id in ("requirements", "system", "download", "write", "partition", "copy", "verify", "done"):
            self.assertIn(stage_id, CORE)

    def test_process_runner_streams_without_blocking_the_ui(self):
        body = function_body(FRONTEND, "Start-BuildProcess")
        self.assertIn("ReadLineAsync", body)
        self.assertIn("DispatcherTimer", body)
        for forbidden in ("ReadToEnd", "OutputDataReceived", "ErrorDataReceived", "BeginOutputReadLine", "DoEvents", "WaitAny"):
            self.assertNotIn(forbidden, body)

    def test_build_process_starts_before_reading_output_streams(self):
        # Regression: Process.StandardOutput/StandardError are null until the
        # process starts; reading them first silently killed every build.
        body = function_body(FRONTEND, "Start-BuildProcess")
        self.assertLess(body.index("[void]$process.Start()"), body.index("$process.StandardOutput.ReadLineAsync()"))
        self.assertLess(body.index("[void]$process.Start()"), body.index("$process.StandardError.ReadLineAsync()"))

    def test_build_pump_survives_faulted_streams_and_handler_errors(self):
        body = function_body(FRONTEND, "Start-BuildProcess")
        self.assertIn("IsFaulted", body)
        self.assertIn("Build output handler error", body)
        self.assertIn("Build pump error", body)
        self.assertIn("Test-BuildProcessExited", body)

    def test_cancel_kills_the_process_tree_and_reports_progress(self):
        body = function_body(FRONTEND, "Stop-BuildProcess")
        self.assertIn("taskkill", body)
        self.assertIn("/T /F", body)
        self.assertIn("Test-BuildProcessExited", body)
        self.assertIn("Cancelling...", body)

    def test_cancel_does_not_offer_the_base_image_retry(self):
        body = function_body(FRONTEND, "Complete-CreatorBuild")
        self.assertIn("-not $script:buildCancelled -and $outputText.Contains('BASE_IMAGE_UNAVAILABLE')", body)

    def test_stall_indicator_waits_for_real_silence(self):
        body = function_body(FRONTEND, "Start-ElapsedTimer")
        self.assertIn("buildLastLineTime", body)
        self.assertIn("no progress reported for", body)

    def test_writer_reports_progress_for_every_phase(self):
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

    def test_writer_network_calls_are_bounded(self):
        self.assertIn("-TimeoutSec 120", WRITER)
        self.assertIn("$request.Timeout = 120000", WRITER)
        self.assertIn("$request.ReadWriteTimeout = 300000", WRITER)

    def test_cancellation_is_gated_on_writer_stage_safety(self):
        body = function_body(FRONTEND, "Set-CurrentStage")
        self.assertIn("Test-WriterCancellationSafe", body)
        cancel_handler = function_body(FRONTEND, "New-CreatorWindow")
        self.assertIn("Stop-BuildProcess", cancel_handler)
        self.assertIn("Test-WriterCancellationSafe -StageId $script:activeStageId", cancel_handler)

    def test_completion_is_only_shown_on_exit_zero(self):
        body = function_body(FRONTEND, "Complete-CreatorBuild")
        self.assertLess(body.index("if ($ExitCode -eq 0)"), body.index("Show-Completion"))
        self.assertLess(body.index("Show-Completion"), body.index("Show-BuildError"))
        self.assertIn("BASE_IMAGE_UNAVAILABLE", body)

    def test_errors_are_plain_language_and_never_claim_success(self):
        body = function_body(FRONTEND, "Show-BuildError")
        self.assertIn("Cancelled", body)
        self.assertIn("BASE_IMAGE_UNAVAILABLE", body)
        self.assertIn("Refusing to write", body)
        self.assertIn("Show-Step -Step 7", body)
        completion = function_body(FRONTEND, "Show-Completion")
        self.assertIn("Show-Step -Step 6", completion)
        self.assertNotIn("Show-Completion", body)

    def test_recommended_profile_is_preselected(self):
        body = function_body(FRONTEND, "New-CreatorWindow")
        self.assertIn("medical-survival", body)
        self.assertIn("$card.IsChecked = $true", body)
        self.assertIn("-Recommended", body)

    def test_unknown_sizes_are_never_treated_as_zero(self):
        self.assertIn("Content catalog is missing a verified size", CORE)
        body = function_body(FRONTEND, "Update-CapacityPanel")
        self.assertIn("RequiredBytesKnown", body)
        self.assertIn("cannot be estimated", body)
        summary = function_body(FRONTEND, "Update-ContentSummary")
        self.assertIn("cannot be estimated", summary)

    def test_learn_more_links_come_from_the_catalog(self):
        self.assertIn("function Open-LearnMoreUrl", FRONTEND)
        self.assertIn("Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop", FRONTEND)
        rows = function_body(FRONTEND, "Rebuild-LibraryRows")
        self.assertIn("LearnMoreUrl", rows)
        self.assertIn("Open-LearnMoreUrl", rows)

    def test_wifi_label_is_written_on_completion(self):
        completion = function_body(FRONTEND, "Show-Completion")
        self.assertIn("New-WifiLabelHtml", completion)
        self.assertIn("EmergencyWebPi-WiFi-Label.html", completion)
        self.assertIn("Get-ApplianceWifiSsid", completion)
        self.assertIn("dynamic-appliance-config.json", FRONTEND)

    def test_home_wifi_controls_are_removed_from_frontend(self):
        for needle in (
            "$chkUpstream",
            "$txtUpstreamSsid",
            "$txtUpstreamPassword",
            "$updateUpstreamAvailability",
            "Use home Wi-Fi for the FirstBoot download",
        ):
            self.assertNotIn(needle, BLOB)

    def test_no_winforms_controls_in_the_normal_ui(self):
        for needle in (
            "System.Windows.Forms.Form",
            "System.Windows.Forms.ListView",
            "System.Windows.Forms.CheckedListBox",
            "SetUnhandledExceptionMode",
            "add_ThreadException",
            "Add_FormClosing",
        ):
            self.assertNotIn(needle, FRONTEND)
        for xaml in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            text = (REPO_ROOT / "portable" / "ui" / xaml).read_text(encoding="utf-8")
            self.assertNotIn("System.Windows.Forms", text)
            self.assertNotIn("x:Class", text)

    def test_ui_thread_exceptions_are_logged(self):
        self.assertIn("add_UnhandledException", FRONTEND)
        self.assertIn("UI thread exception", FRONTEND)
        self.assertIn("Unhandled error", FRONTEND)

    def test_logs_rotate_and_live_next_to_the_app(self):
        self.assertIn("startup-", FRONTEND)
        self.assertRegex(FRONTEND, r"Select-Object -Skip 10")
        self.assertIn("BtnDevOpenLogs", FRONTEND)

    def test_frontend_scripts_are_pure_ascii_without_bom(self):
        for relative in (
            "portable/EmergencyWebPi.ps1",
            "portable/EmergencyWebPi-Core.ps1",
            "portable/ui/MainWindow.xaml",
            "portable/ui/DeveloperTools.xaml",
            "portable/ui/ConfirmErase.xaml",
            "tests/test_frontend_core.ps1",
        ):
            raw = (REPO_ROOT / relative).read_bytes()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), relative + " must not have a BOM")
            raw.decode("ascii")

    def test_core_module_is_side_effect_free_when_dot_sourced(self):
        # The module must define functions only: no top-level executable statements
        # beyond param/comment lines would be acceptable, so check for obvious ones.
        for forbidden in ("Start-Process", "Set-Content", "New-Item", "Remove-Item", "Write-Host"):
            self.assertNotIn(forbidden, CORE)

    def test_writer_argument_contract_is_frozen(self):
        body = function_body(CORE, "New-PrebuiltBuildArguments")
        for needle in (
            '"-DiskNumber", $DiskNumber',
            '"-ConfirmDiskNumber", $DiskNumber',
            '"-Force"',
            '"-Profile"',
            '"-ContentDir"',
            '"-WorkspaceDir"',
            '"-ReleaseRepo"',
            '"-DeviceConfigPath"',
            '"-ContentMode"',
        ):
            self.assertIn(needle, body)
        self.assertIn('"-ImagePath"', body)
        self.assertIn("$parts -join", body)

    def test_config_json_matches_the_pi_device_config_schema(self):
        body = function_body(CORE, "New-ApplianceConfigJsonText")
        self.assertIn("schemaVersion = 1", body)
        self.assertIn("ssid", body)
        self.assertIn("password", body)
        reader = function_body(FRONTEND, "Get-ApplianceWifiSsid")
        self.assertIn("$config.ap.ssid", reader)


if __name__ == "__main__":
    unittest.main()
