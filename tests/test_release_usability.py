from __future__ import annotations

import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

class ReleaseUsabilityTests(unittest.TestCase):
    """Regression coverage for the end-user ("monkey test") fixes."""

    def test_frontend_requests_elevation_automatically(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        # The app must request elevation itself instead of failing later on disk access.
        self.assertIn("-Verb RunAs", frontend)
        self.assertIn("Test-IsAdministrator", frontend)
        self.assertIn("needs administrator permission to write the SD card", frontend)

    def test_frontend_uses_bundled_aria2_without_path_install(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        dynamic = (REPO_ROOT / "scripts" / "create-sd-dynamic.ps1").read_text(encoding="utf-8")
        for text in (frontend, dynamic):
            self.assertIn("tools\\aria2", text)
            self.assertIn("aria2c.exe", text)

    def test_frontend_shows_and_saves_wifi_credentials(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        self.assertIn("dynamic-appliance-config.json", frontend)
        self.assertIn("EmergencyWebPi-WiFi-Label.html", frontend)
        self.assertIn("Emergency Wi-Fi name", frontend)

    def test_packaging_bundles_verified_aria2(self) -> None:
        packaging = (REPO_ROOT / "scripts" / "package-portable.ps1").read_text(encoding="utf-8")
        self.assertIn("config\\aria2.json", packaging)
        self.assertIn("failed SHA-256 verification", packaging)
        self.assertIn("tools\\aria2", packaging)
        manifest = (REPO_ROOT / "config" / "aria2.json").read_text(encoding="utf-8")
        self.assertIn("sha256", manifest)
        self.assertIn("downloadUrl", manifest)

    def test_install_sh_installs_initial_sync_service(self) -> None:
        install = (REPO_ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("pi-kiwix-initial-sync.service /etc/systemd/system/", install)
        self.assertIn("systemctl enable pi-kiwix-initial-sync.service", install)
        # A first sync can run for hours; it must not block the installer.
        self.assertIn("systemctl start --no-block pi-kiwix-sync.service", install)
        self.assertNotIn("\nsudo systemctl start pi-kiwix-sync.service\n", install)

    def test_setup_ap_rejects_default_passphrase(self) -> None:
        setup_ap = (REPO_ROOT / "scripts" / "setup-ap.sh").read_text(encoding="utf-8")
        self.assertIn("ChangeThisPassphrase123", setup_ap)

    def test_third_party_notices_cover_bundled_aria2(self) -> None:
        notices = (REPO_ROOT / "docs" / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn("aria2", notices)
        self.assertIn("GPL-2.0-or-later", notices)

    def test_readme_documents_card_size_and_firstrun_wiring(self) -> None:
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("128 GB card", readme)
        # A manually copied firstrun.sh is inert on Raspberry Pi OS;
        # the supported wiring must be documented instead.
        self.assertIn("does **not** execute a `firstrun.sh`", readme)
        self.assertIn("prepare-sd-autoboot.ps1", readme)

if __name__ == "__main__":
    unittest.main()