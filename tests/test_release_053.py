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

    def test_prebuilt_is_selected_by_default_in_wizard_source(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn('$chkDownloadOnPi.Checked = $false', frontend)
        self.assertIn('$optPrebuilt.Checked = $true', frontend)
        self.assertIn('Advanced: download selected content on first boot', frontend)

    def test_wizard_shows_library_descriptions_inline(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn('New-Object System.Windows.Forms.ListView', frontend)
        self.assertIn('Columns.Add("Description"', frontend)
        self.assertNotIn('$btnLearnMore.Text = "Learn More"', frontend)

    def test_home_wifi_is_scoped_to_first_boot_mode(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn('FirstBoot only: use home Wi-Fi for the automatic download', frontend)
        self.assertIn('$chkUpstream.Enabled = $firstBootSelected', frontend)
        self.assertIn('$optPrebuilt.Add_CheckedChanged($updateUpstreamAvailability)', frontend)

    def test_primary_wizard_button_has_room_for_its_label(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn('$btnStartWizard.Text = "Estimate + Build"', frontend)
        self.assertIn('$btnStartWizard.Width = 120', frontend)

    def test_all_services_use_dedicated_non_root_account(self) -> None:
        for service in (REPO_ROOT / "scripts" / "systemd").glob("*.service"):
            text = service.read_text(encoding="utf-8")
            self.assertIn("User=emergency-web-pi", text, service.name)
            self.assertIn("Group=emergency-web-pi", text, service.name)

    def test_handoff_is_after_initial_sync_and_not_setup_time(self) -> None:
        setup_ap = (REPO_ROOT / "scripts" / "setup-ap.sh").read_text(encoding="utf-8")
        initial_sync = (REPO_ROOT / "scripts" / "systemd" / "pi-kiwix-initial-sync.service").read_text(encoding="utf-8")
        handoff = (REPO_ROOT / "scripts" / "switch-to-ap.sh").read_text(encoding="utf-8")
        self.assertNotIn("connection down emergency-web-pi-upstream", setup_ap)
        self.assertIn("ExecStart=__REPO_DIR__/scripts/sync.sh --initial", initial_sync)
        self.assertIn("ExecStartPost=__REPO_DIR__/scripts/switch-to-ap.sh", initial_sync)
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
