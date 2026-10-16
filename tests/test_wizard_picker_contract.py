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
        match = re.search(r"\$btnDynamic\.Add_Click\(\{", FRONTEND)
        handler = FRONTEND[match.start():FRONTEND.index("$btnDisks.Add_Click")]
        self.assertGreaterEqual(handler.count("Exit-OrReturnToWizard"), 4)


if __name__ == "__main__":
    unittest.main()
