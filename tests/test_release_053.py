from __future__ import annotations

import io
import importlib.util
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
STATUS_WEB_PATH = REPO_ROOT / "scripts" / "status-web.py"
SPEC = importlib.util.spec_from_file_location("status_web_053", STATUS_WEB_PATH)
assert SPEC and SPEC.loader
status_web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(status_web)


class FakeRequest:
    def __init__(self, path: str, host: str = "10.42.0.1:80") -> None:
        self.path = path
        self.headers = {"Host": host}
        self.responses: list[int] = []
        self.body = io.BytesIO()
        self.wfile = self.body
        self.sent_headers: list[tuple[str, str]] = []

    def send_response(self, code: int) -> None:
        self.responses.append(code)

    def send_header(self, name: str, value: str) -> None:
        self.sent_headers.append((name, value))

    def end_headers(self) -> None:
        pass


class Release053Tests(unittest.TestCase):
    @staticmethod
    def page_status() -> dict[str, object]:
        return {
            "ready": False,
            "kiwixActive": False,
            "syncActive": False,
            "zimCount": 0,
            "lastSyncLine": "No sync log yet",
            "zimDataMounted": True,
            "contentInstallPending": False,
            "expectedZimCount": 0,
            "contentProgressPercent": 0,
        }

    def test_prebuilt_is_selected_by_default_in_creator_source(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        creator_xaml = (REPO_ROOT / "portable" / "ui" / "MainWindow.xaml").read_text(encoding="utf-8")
        self.assertIn("ContentMode = 'Prebuilt'", frontend)
        self.assertIn("$optPrebuilt.IsChecked = ($script:app.ContentMode -eq 'Prebuilt')", frontend)
        self.assertIn('x:Name="OptPrebuilt"', creator_xaml)
        self.assertIn('x:Name="OptFirstBoot"', creator_xaml)
        self.assertIn("Prepare everything now", creator_xaml)
        self.assertIn("Download content on first boot", creator_xaml)

    def test_creator_shows_library_descriptions_inline(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        creator_xaml = (REPO_ROOT / "portable" / "ui" / "MainWindow.xaml").read_text(encoding="utf-8")
        self.assertIn('x:Key="LibraryCheck"', creator_xaml)
        self.assertIn("New-UiText $item.Description", frontend)
        self.assertIn("New-UiText $item.Name", frontend)
        self.assertNotIn("System.Windows.Forms.ListView", frontend)

    def test_home_wifi_option_is_removed_from_wizard(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        for needle in (
            "Use home Wi-Fi for the FirstBoot download",
            "$chkUpstream",
            "$txtUpstreamSsid",
            "$txtUpstreamPassword",
            "$updateUpstreamAvailability",
        ):
            self.assertNotIn(needle, frontend)
        prebuilt = (REPO_ROOT / "scripts" / "create-sd-prebuilt.ps1").read_text(encoding="utf-8")
        self.assertNotIn("UpstreamSsid", prebuilt)
        self.assertNotIn("UpstreamPassword", prebuilt)

    def test_creator_displays_app_and_raspberry_pi_os_versions(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        creator_xaml = (REPO_ROOT / "portable" / "ui" / "MainWindow.xaml").read_text(encoding="utf-8")
        dev_xaml = (REPO_ROOT / "portable" / "ui" / "DeveloperTools.xaml").read_text(encoding="utf-8")
        self.assertIn("'Version ' + $script:appVersion", frontend)
        self.assertIn("$script:appVersion = 'dev'", frontend)
        self.assertIn('x:Name="VersionText"', creator_xaml)
        self.assertIn('x:Name="DevBaseInfo"', dev_xaml)
        self.assertIn("$base.Codename", frontend)

    def test_primary_creator_button_carries_the_create_action(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        creator_xaml = (REPO_ROOT / "portable" / "ui" / "MainWindow.xaml").read_text(encoding="utf-8")
        self.assertIn("'Create Emergency Web Pi'", frontend)
        self.assertIn('x:Name="BtnContinue"', creator_xaml)
        self.assertIn('Style="{StaticResource PrimaryButton}"', creator_xaml)

    def test_all_services_use_dedicated_non_root_account(self) -> None:
        # The first-boot credential oneshot writes root-only NetworkManager profiles, so it is the sole root unit.
        root_units = {"pi-kiwix-device-config.service"}
        for service in (REPO_ROOT / "scripts" / "systemd").glob("*.service"):
            if service.name in root_units:
                continue
            text = service.read_text(encoding="utf-8")
            self.assertIn("User=emergency-web-pi", text, service.name)
            self.assertIn("Group=emergency-web-pi", text, service.name)

    def test_handoff_is_after_initial_sync_and_not_setup_time(self) -> None:
        setup_ap = (REPO_ROOT / "scripts" / "setup-ap.sh").read_text(encoding="utf-8")
        initial_sync = (REPO_ROOT / "scripts" / "systemd" / "pi-kiwix-initial-sync.service").read_text(encoding="utf-8")
        handoff = (REPO_ROOT / "scripts" / "switch-to-ap.sh").read_text(encoding="utf-8")
        self.assertNotIn("connection down emergency-web-pi-upstream", setup_ap)
        self.assertIn("ExecStart=__REPO_DIR__/scripts/sync.sh --initial", initial_sync)
        # The leading "+" makes the AP handoff run as root; the old per-command
        # privilege directive was deprecated upstream and ignored since systemd 240.
        self.assertIn("ExecStartPost=+__REPO_DIR__/scripts/switch-to-ap.sh", initial_sync)
        self.assertNotIn("PermissionsStartOnly", initial_sync)
        self.assertIn("connection down emergency-web-pi-upstream", handoff)
        self.assertIn("connection.autoconnect no", handoff)
        self.assertIn("connection up pi-kiwix-ap", handoff)

    def test_upstream_enabled_images_do_not_autostart_the_ap(self) -> None:
        builder = (REPO_ROOT / "scripts" / "build-appliance-image.sh").read_text(encoding="utf-8")
        self.assertIn("ap_autoconnect=false", builder)
        self.assertIn("autoconnect=$ap_autoconnect", builder)

    def test_android_captive_endpoints_signal_portal(self) -> None:
        for path in ("/generate_204", "/gen_204"):
            request = FakeRequest(path)
            request._status = self.page_status
            request.kiwix_port = 8080
            status_web.StatusHandler.do_GET(request)
            self.assertEqual([200], request.responses, path)

    def test_status_catch_all_uses_request_host_for_library_link(self) -> None:
        request = FakeRequest("/unknown", "192.168.4.1:80")
        request._status = self.page_status
        request.kiwix_port = 8080
        status_web.StatusHandler.do_GET(request)
        self.assertEqual([200], request.responses)
        self.assertIn(b"http://192.168.4.1:8080", request.body.getvalue())

    def test_temp_extraction_guard_is_present(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn("temporary extraction path", frontend)
        self.assertIn("$env:TEMP", frontend)
        self.assertIn("Refusing to run", frontend)


if __name__ == "__main__":
    unittest.main()
