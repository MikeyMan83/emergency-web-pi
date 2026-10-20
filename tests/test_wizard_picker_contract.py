import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FRONTEND = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")


def function_body(name: str) -> str:
    match = re.search(r"^function %s\b[^{]*\{" % re.escape(name), FRONTEND, re.MULTILINE)
    assert match, f"function {name} not found"
    depth = 1
    pos = match.end()
    while depth and pos < len(FRONTEND):
        char = FRONTEND[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        pos += 1
    return FRONTEND[match.end():pos]


class WizardPickerContractTests(unittest.TestCase):
    def test_wizard_selection_adds_catalog_items_not_strings(self):
        body = function_body("Start-EndUserFlow")
        adds = re.findall(r"\$lstProfileItems\.Items\.Add\(([^\n]*)\)", body)
        self.assertTrue(adds, "wizard must populate the picker")
        for call in adds:
            self.assertIn("Get-CatalogItem", call)

    def test_resolver_accepts_string_and_object_items(self):
        body = function_body("Resolve-EntriesForDynamicRun")
        self.assertIn("-is [string]", body)
        self.assertIn("[string]$item.Url", body)
        self.assertIn("No profile items selected in picker.", body)

    def test_recoverable_aborts_return_to_wizard(self):
        helper = function_body("Exit-OrReturnToWizard")
        self.assertIn("Start-EndUserFlow", helper)
        body = function_body("Invoke-DynamicBuild")
        self.assertGreaterEqual(body.count("Exit-OrReturnToWizard"), 4)

    def test_wizard_hands_off_by_direct_call_not_perform_click(self):
        body = function_body("Start-EndUserFlow")
        self.assertIn("Invoke-DynamicBuild", body)
        self.assertNotIn("PerformClick", body)

    def test_wizard_click_handler_is_exception_guarded(self):
        body = function_body("Show-EndUserWizard")
        start = body.index("$btnStartWizard.Add_Click")
        end = body.index("$wizard.Add_FormClosing")
        handler = body[start:end]
        self.assertRegex(handler, r"\btry\s*\{")
        self.assertRegex(handler, r"\}\s*catch\s*\{")
        self.assertIn("Wizard build button threw", handler)

    def test_wizard_handoff_is_logged(self):
        body = function_body("Show-EndUserWizard")
        self.assertIn("Wizard form closing: CloseReason", body)
        self.assertIn("End-user wizard closed with result", body)
        self.assertIn("End-user wizard result object present", body)

    def test_null_selection_shows_message_before_closing(self):
        body = function_body("Start-EndUserFlow")
        start = body.index("if ($null -eq $selection)")
        branch = body[start:body.index("if ($selection.DeveloperTools)")]
        self.assertIn("Wizard returned no selection", branch)
        self.assertIn("MessageBox]::Show", branch)
        self.assertLess(branch.index("MessageBox]::Show"), branch.index("$form.Close()"))

    def test_ui_thread_exceptions_are_logged(self):
        self.assertIn("SetUnhandledExceptionMode", FRONTEND)
        self.assertIn("add_ThreadException", FRONTEND)
        self.assertIn("UI thread exception", FRONTEND)

    def test_logs_prefer_install_dir_and_rotate(self):
        self.assertRegex(FRONTEND, r'Join-Path \$appRootDirectory "logs"')
        self.assertIn("Log directory resolved", FRONTEND)
        self.assertRegex(FRONTEND, r"Select-Object -Skip 10")
        self.assertIn("Open logs", FRONTEND)

    def test_home_wifi_controls_are_removed_from_frontend(self):
        for needle in (
            "$chkUpstream",
            "$txtUpstreamSsid",
            "$txtUpstreamPassword",
            "$updateUpstreamAvailability",
            "Use home Wi-Fi for the FirstBoot download",
        ):
            self.assertNotIn(needle, FRONTEND)

    def test_dynamic_build_uses_build_args_variable(self):
        body = function_body("Invoke-DynamicBuild")
        self.assertNotIn("$args", body)
        self.assertIn("-Arguments $buildArgs", body)

    def test_powershell_script_pumps_output_to_status_label(self):
        body = function_body("Invoke-PowerShellScript")
        for needle in ("ReadLineAsync", "WaitAny", "DoEvents", "$StatusLabel"):
            self.assertIn(needle, body)
        for needle in ("ReadToEnd", "add_OutputDataReceived", "add_ErrorDataReceived", "BeginOutputReadLine"):
            self.assertNotIn(needle, body)

    def test_wizard_marks_user_closing_as_cancel(self):
        body = function_body("Show-EndUserWizard")
        start = body.index("$wizard.Add_FormClosing")
        end = body.index("$dialogResult =")
        handler = body[start:end]
        self.assertIn("CloseReason]::UserClosing", handler)
        self.assertIn("$script:wizardCancelClicked = $true", handler)

    def test_frontend_is_pure_ascii_without_bom(self):
        raw = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_bytes()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
        raw.decode("ascii")


if __name__ == "__main__":
    unittest.main()
