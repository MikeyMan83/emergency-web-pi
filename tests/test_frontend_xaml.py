import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
UI_DIR = REPO_ROOT / "portable" / "ui"
MAIN_XAML = (UI_DIR / "MainWindow.xaml").read_text(encoding="utf-8")
DEV_XAML = (UI_DIR / "DeveloperTools.xaml").read_text(encoding="utf-8")
CONFIRM_XAML = (UI_DIR / "ConfirmErase.xaml").read_text(encoding="utf-8")

XAML_NS = "{http://schemas.microsoft.com/winfx/2006/xaml/presentation}"
X_NS = "{http://schemas.microsoft.com/winfx/2006/xaml}"


def named_elements(xaml_text: str) -> set[str]:
    root = ET.fromstring(xaml_text)
    names = set()
    for element in root.iter():
        name = element.attrib.get(f"{X_NS}Name") or element.attrib.get("Name")
        if name:
            names.add(name)
    return names


def resource_keys(xaml_text: str) -> set[str]:
    root = ET.fromstring(xaml_text)
    keys = set()
    for element in root.iter():
        key = element.attrib.get("{http://schemas.microsoft.com/winfx/2006/xaml}Key")
        if key:
            keys.add(key)
    return keys


class XamlWellFormedTests(unittest.TestCase):
    def test_all_windows_are_well_formed_xml(self):
        for name in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            path = UI_DIR / name
            try:
                ET.fromstring(path.read_text(encoding="utf-8"))
            except ET.ParseError as error:
                self.fail(f"{name} is not well-formed XML: {error}")

    def test_windows_are_wpf_windows_without_code_behind(self):
        for name in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            text = (UI_DIR / name).read_text(encoding="utf-8")
            root = ET.fromstring(text)
            self.assertEqual(XAML_NS + "Window", root.tag, name)
            self.assertNotIn("x:Class", text, name)
            self.assertIn('xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"', text, name)

    def test_xaml_files_are_pure_ascii_without_bom(self):
        for name in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            raw = (UI_DIR / name).read_bytes()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), name + " must not have a BOM")
            raw.decode("ascii")


class CreatorWindowStructureTests(unittest.TestCase):
    def setUp(self):
        self.names = named_elements(MAIN_XAML)

    def test_all_workflow_pages_exist(self):
        for page in ("PageContent", "PageInstall", "PageSd", "PageReview", "PageProgress", "PageDone", "PageError"):
            self.assertIn(page, self.names)

    def test_step_indicator_is_complete(self):
        for index in range(1, 5):
            for part in ("StepDot", "StepDotText", "StepLabel"):
                self.assertIn(f"{part}{index}", self.names)
        for index in range(1, 4):
            self.assertIn(f"StepLine{index}", self.names)
        for label in ("Content", "Installation", "SD card", "Review"):
            self.assertIn(f'Text="{label}"', MAIN_XAML)

    def test_content_step_elements(self):
        for control in ("ProfileCardHost", "CustomizeExpander", "CustomizeSummary", "BtnSelectAll", "BtnSelectNone", "LibraryListHost"):
            self.assertIn(control, self.names)
        self.assertIn("What do you want available offline?", MAIN_XAML)
        self.assertIn("Choose the information you want to keep available when the Internet is unavailable.", MAIN_XAML)
        self.assertIn("Customize content", MAIN_XAML)

    def test_install_step_elements(self):
        for control in ("OptPrebuilt", "OptFirstBoot"):
            self.assertIn(control, self.names)
        self.assertIn("How would you like to prepare your offline library?", MAIN_XAML)
        self.assertIn("Prepare everything now", MAIN_XAML)
        self.assertIn("Download content on first boot", MAIN_XAML)
        self.assertIn("No Internet required on first boot", MAIN_XAML)
        self.assertIn("The Raspberry Pi needs Internet access to retrieve content initially", MAIN_XAML)

    def test_sd_step_elements(self):
        for control in ("SdStatusText", "BtnRefreshDisks", "DiskListHost", "SdEmptyState", "SdEmptyRefresh", "SdWarning", "CapacityPanel", "CapacitySummary", "CapacityTrack", "CapacityFill"):
            self.assertIn(control, self.names)
        self.assertIn("Where should Emergency Web Pi be installed?", MAIN_XAML)
        self.assertIn("No SD card detected", MAIN_XAML)

    def test_review_step_elements(self):
        for control in ("RevContent", "RevInstall", "RevCard", "RevSize", "RevInternet"):
            self.assertIn(control, self.names)
        self.assertIn("Ready to create your Emergency Web Pi?", MAIN_XAML)
        self.assertIn("All existing data on the selected SD card will be erased.", MAIN_XAML)

    def test_progress_step_elements(self):
        for control in ("ProgressTitle", "ProgressElapsed", "StageListHost", "BuildBarTrack", "BuildBarFill", "ProgressStatus", "BtnCancel", "CancelNote", "DetailsExpander", "DetailsExpanderLabel", "LogTail"):
            self.assertIn(control, self.names)
        self.assertIn("Creating your Emergency Web Pi", MAIN_XAML)
        self.assertIn("Show details", MAIN_XAML)
        self.assertIn("Cancelling is not safe while the card is being written.", MAIN_XAML)

    def test_done_step_elements(self):
        for control in ("WifiSsidText", "WifiPasswordText", "WifiLabelNote", "BtnShowInstructions", "BtnViewLog", "BtnFinish"):
            self.assertIn(control, self.names)
        self.assertIn("Your Emergency Web Pi is ready.", MAIN_XAML)
        self.assertIn("Emergency Wi-Fi name", MAIN_XAML)
        self.assertIn("Emergency Wi-Fi password", MAIN_XAML)
        self.assertIn("Safely eject the SD card from this PC.", MAIN_XAML)

    def test_error_step_elements(self):
        for control in ("ErrorMessage", "ErrorHint", "ErrorDetailsExpander", "ErrorLogTail", "BtnBackToReview", "BtnErrorFinish"):
            self.assertIn(control, self.names)
        self.assertIn("Creating the SD card did not finish", MAIN_XAML)

    def test_navigation_and_developer_entry_points(self):
        for control in ("FooterBar", "BtnBack", "BtnContinue", "FooterHint", "BtnDeveloperTools", "VersionText"):
            self.assertIn(control, self.names)

    def test_design_system_resources_exist(self):
        keys = resource_keys(MAIN_XAML)
        for key in (
            "CanvasBrush", "BrandBrush", "InkBrush", "MutedBrush", "BorderBrush", "SurfaceBrush",
            "SuccessBrush", "WarningBrush", "DangerBrush",
            "PageTitle", "PageSubtitle", "SectionLabel", "BodyText", "MutedText", "MetaText",
            "PrimaryButton", "SecondaryButton", "SmallButton", "DangerButton",
            "CardRadio", "LibraryCheck", "SectionExpander", "Banner", "BannerText",
            "SummaryLabel", "SummaryValue", "LogBox", "LinkText",
        ):
            self.assertIn(key, keys)

    def test_semantic_colours_do_not_rely_on_colour_alone(self):
        # Status text is always paired with a coloured pill; the erase banner
        # spells the consequence out in words.
        self.assertIn("erased", MAIN_XAML)
        self.assertIn("will be deleted", MAIN_XAML)


class XamlResourceReferenceTests(unittest.TestCase):
    def test_static_resources_inside_templates_are_defined_earlier(self):
        # StaticResource inside a ControlTemplate is resolved when the template is
        # loaded, not when the window is parsed: it cannot see keys that are defined
        # later in the same resource dictionary (forward references fail at runtime
        # with "Cannot find resource named ...").
        import re

        key_re = re.compile(r'x:Key="([A-Za-z0-9_]+)"')
        ref_re = re.compile(r"\{StaticResource ([A-Za-z0-9_]+)\}")
        for name in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            lines = (UI_DIR / name).read_text(encoding="utf-8").splitlines()
            key_line = {}
            for index, line in enumerate(lines, start=1):
                for match in key_re.finditer(line):
                    key_line.setdefault(match.group(1), index)
            template_depth = 0
            for index, line in enumerate(lines, start=1):
                if "<ControlTemplate" in line:
                    template_depth += 1
                if template_depth > 0:
                    for match in ref_re.finditer(line):
                        key = match.group(1)
                        self.assertIn(key, key_line, f"{name}:{index}: StaticResource '{key}' has no definition")
                        self.assertLess(
                            key_line[key],
                            index,
                            f"{name}:{index}: StaticResource '{key}' is defined later (line {key_line[key]}); forward references fail at template load",
                        )
                if "</ControlTemplate>" in line:
                    template_depth -= 1

    def test_template_attributes_reference_templates_not_styles(self):
        # Template="{StaticResource X}" must resolve to a ControlTemplate/DataTemplate
        # resource; pointing it at a Style throws "Style is not a valid value for
        # property Template" when the owning template is applied at runtime.
        import re

        template_ref_re = re.compile(r'\bTemplate="\{StaticResource ([A-Za-z0-9_]+)\}"')
        for name in ("MainWindow.xaml", "DeveloperTools.xaml", "ConfirmErase.xaml"):
            text = (UI_DIR / name).read_text(encoding="utf-8")
            key_elements = {}
            for element in ET.fromstring(text).iter():
                key = element.attrib.get(f"{X_NS}Key")
                if key:
                    key_elements[key] = element.tag
            for match in template_ref_re.finditer(text):
                key = match.group(1)
                self.assertIn(key, key_elements, f"{name}: Template references unknown resource '{key}'")
                tag = key_elements[key]
                self.assertIn(
                    tag,
                    (XAML_NS + "ControlTemplate", XAML_NS + "DataTemplate", XAML_NS + "HierarchicalDataTemplate"),
                    f"{name}: Template references '{key}' which is a {tag} resource, not a template",
                )


class DeveloperToolsStructureTests(unittest.TestCase):
    def setUp(self):
        self.names = named_elements(DEV_XAML)

    def test_all_sections_exist(self):
        for control in (
            "DevBaseInfo", "BtnCheckPrereqs", "BtnBuildImage", "DevBuildStatus",
            "CmbDevProfiles", "BtnDevRefreshProfiles", "BtnDevLoadProfile", "DevContentInfo", "DevLibraryHost",
            "CmbDevDisks", "BtnDevRefreshDisks", "BtnDevEstimate", "BtnDevDynamicBuild", "BtnDevWriteImage", "DevSdStatus",
            "DevLog", "BtnDevOpenWorkspace", "BtnDevOpenLogs", "BtnDevAbout",
            "DevAdvVersion", "DevAdvRepoRoot", "DevAdvWorkspace", "DevAdvCache", "DevAdvBaseManifest", "DevAdvGeneratedProfiles", "DevAdvLogs", "TxtDevReleaseRepo",
            "BtnDevClose",
        ):
            self.assertIn(control, self.names)

    def test_section_tabs_are_labelled(self):
        for label in ("Build", "Content", "SD &amp; Output", "Diagnostics", "Advanced"):
            self.assertIn(label, DEV_XAML)


class ConfirmEraseStructureTests(unittest.TestCase):
    def setUp(self):
        self.names = named_elements(CONFIRM_XAML)

    def test_dialog_identifies_the_device_and_the_consequence(self):
        for control in ("ConfirmTitle", "ConfirmDevice", "ConfirmBody", "BtnConfirmCancel", "BtnConfirmErase"):
            self.assertIn(control, self.names)
        self.assertIn("Erase and create", CONFIRM_XAML)


if __name__ == "__main__":
    unittest.main()
