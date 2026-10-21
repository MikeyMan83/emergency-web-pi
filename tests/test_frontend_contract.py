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


    def test_cancel_never_blocks_the_ui_thread(self):
        body = function_body(FRONTEND, "Stop-BuildProcess")
        # Idempotent: a second cancel click must not start a second kill.
        self.assertIn("$script:buildStopRequested", body)
        # The UI thread must never wait for the writer to die.
        self.assertNotIn("WaitForExit", body)
        self.assertNotIn(".Wait(", body)
        # No Task.Run: PowerShell scriptblocks have no runspace on a task thread.
        self.assertNotIn("Task.Run", body)
        # taskkill kills the tree immediately; a dispatcher tick force-kills the
        # writer as a fallback, reading the target from a script variable because
        # delegate handlers cannot see function locals.
        self.assertIn("DispatcherTimer", body)
        self.assertIn("$script:buildKillTarget", body)
        self.assertIn("param($sender, $eventArgs)", body)
        self.assertIn("$target.Kill()", body)

    def test_build_pump_treats_canceled_reads_as_end_of_stream(self):
        body = function_body(FRONTEND, "Start-BuildProcess")
        # A killed process can fault or cancel a pending read; both are EOF.
        self.assertIn("IsFaulted -or $task.IsCanceled", body)

    def test_build_pump_has_cancel_and_orphan_grace_periods(self):
        body = function_body(FRONTEND, "Start-BuildProcess")
        # After cancel or after the writer exits, give the pipes a grace period
        # so a surviving grandchild cannot hold the completion back forever.
        self.assertIn("cancelGrace", body)
        self.assertIn("orphanGrace", body)
        self.assertIn("Build process finished (exit code", body)

    def test_progress_bar_is_monotonic_across_stage_transitions(self):
        body = function_body(FRONTEND, "Set-BuildBarPercent")
        self.assertIn("$script:buildBarPercent", body)
        self.assertIn("$percent -gt $script:buildBarPercent", body)
        stage = function_body(FRONTEND, "Set-CurrentStage")
        # Entering a stage moves the bar to the stage base, never back to zero.
        self.assertIn("Get-CreatorStageBasePercent", stage)
        self.assertIn("Set-BuildBarPercent -Percent $base", stage)
        self.assertNotIn("Set-BuildBarPercent -Percent 0", stage)

    def test_progress_covers_the_whole_workflow(self):
        body = function_body(FRONTEND, "Invoke-BuildLine")
        for needle in ("Get-SystemPercentForLine", "Get-DownloadStagePercent", "Get-ItemStagePercent", "Set-ActiveStagePercent"):
            self.assertIn(needle, body)
        self.assertIn("'^Content download complete'", body)
        self.assertIn("'^Copied: (.+)$'", body)
        active = function_body(FRONTEND, "Set-ActiveStagePercent")
        self.assertIn("Get-CreatorOverallPercent", active)
        start = function_body(FRONTEND, "Start-CreatorBuild")
        for needle in ("$script:downloadTotalWeight", "$script:copyTotalCount", "$script:buildBarPercent = 0", "Set-CurrentStage -StageId 'requirements'"):
            self.assertIn(needle, start)

    def test_stage_weights_define_whole_workflow_progress(self):
        for needle in ("function Get-CreatorStageWeights", "function Get-CreatorStageBasePercent", "function Get-CreatorOverallPercent", "function Get-SystemPercentForLine"):
            self.assertIn(needle, CORE)

    def test_base_image_fallback_offers_the_ewp_base_image(self):
        body = function_body(FRONTEND, "Complete-CreatorBuild")
        # The fallback must ask for the Emergency Web Pi base image (the writer
        # needs an ewp-base image plus its manifest), not a raw Raspberry Pi OS image.
        self.assertIn("Select the Emergency Web Pi base image", body)
        self.assertIn("*.img;*.img.gz;*.001", body)
        self.assertIn("ewp-base-*.img.manifest.json", body)
        self.assertIn("ManifestPathOverride", body)
        self.assertNotIn("Select the Raspberry Pi OS image", body)
        self.assertNotIn("*.img.xz", body)

    def test_base_image_fallback_resets_progress_for_the_retry(self):
        body = function_body(FRONTEND, "Complete-CreatorBuild")
        self.assertIn("$script:buildBarPercent = 0", body)
        self.assertIn("$script:activeStageId = $null", body)

    def test_error_mapping_distinguishes_workspace_and_sd_space(self):
        body = function_body(FRONTEND, "Show-BuildError")
        self.assertIn("Not enough free space on the workspace drive", body)
        self.assertIn("Not enough free space on the SD card", body)

    def test_writer_downloads_are_atomic_and_cache_is_verified(self):
        self.assertIn(".partial", WRITER)
        self.assertIn("Move-Item $partialPath $Destination", WRITER)
        self.assertIn("Removing incomplete base image download", WRITER)
        self.assertIn("Verifying cached base image asset (SHA-256).", WRITER)
        self.assertIn("Cached base image asset failed verification", WRITER)
        self.assertIn("function Get-ExpectedAssetSha256", WRITER)

    def test_writer_checks_free_space_before_downloading(self):
        self.assertIn("Not enough free space on the workspace drive", WRITER)
        self.assertIn("function Get-DriveFreeBytes", WRITER)
        download_fn = function_body(WRITER, "Download-BaseImageAssets")
        self.assertLess(download_fn.index("Checking available disk space."), download_fn.index("Save-ReleaseAsset -Asset $info.Asset"))

    def test_writer_reports_system_and_copy_progress(self):
        for needle in ('"System files: 0%"', '"System files: 100%"', '"Preparing to download selected content."', '"Content download complete."', '"Copied: $($item.name)"', '"Checking available disk space."'):
            self.assertIn(needle, WRITER)

    def test_writer_manifest_requires_distribution_hashes(self):
        body = function_body(WRITER, "Validate-PrebuiltManifest")
        self.assertIn("Manifest is missing name, sizeBytes, or sha256 for an image part.", body)
        self.assertIn("Manifest is missing distribution.file, sizeBytes, or sha256.", body)

    def test_writer_checks_sd_space_before_the_destructive_write(self):
        self.assertLess(WRITER.index("Not enough free space on the SD card"), WRITER.index("Write-ImageToDisk -ImagePath $rawImage"))


if __name__ == "__main__":
    unittest.main()
