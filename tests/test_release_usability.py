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

    def test_validate_repo_matches_initial_sync_service(self) -> None:
        validate = (REPO_ROOT / "scripts" / "validate_repo.py").read_text(encoding="utf-8")
        initial_sync = (REPO_ROOT / "scripts" / "systemd" / "pi-kiwix-initial-sync.service").read_text(encoding="utf-8")
        # The CI invariant script must expect the same root-privileged AP
        # handoff the service file actually uses (systemd "+" exec prefix).
        self.assertIn("ExecStartPost=+__REPO_DIR__/scripts/switch-to-ap.sh", initial_sync)
        self.assertIn('"ExecStartPost=+__REPO_DIR__/scripts/switch-to-ap.sh" in initial_sync_service', validate)

    def test_wsl_gate_lives_only_on_the_developer_path(self) -> None:
        frontend = (REPO_ROOT / "portable" / "EmergencyWebPi.ps1").read_text(encoding="utf-8")
        # The dynamic builder still needs WSL; its guard stays, but the
        # end-user flow must not require it.
        self.assertIn("function Test-WslReady", frontend)
        self.assertIn("Show-WslSetupGuidance", frontend)
        self.assertIn("wsl --install -d Ubuntu", frontend)
        end_user_flow = frontend.split("function Start-EndUserFlow", 1)[1].split("$btnWizard.Add_Click", 1)[0]
        self.assertNotIn("Test-WslReady", end_user_flow)
        self.assertNotIn("Show-WslSetupGuidance", end_user_flow)
        self.assertIn("if (-not $script:prebuiltFlow -and -not (Test-WslReady))", frontend)

    def test_release_status_supports_private_repositories(self) -> None:
        release_status = (REPO_ROOT / "scripts" / "release-status.ps1").read_text(encoding="utf-8")
        # The GitHub API answers 404 for a private repo without a token;
        # the checker must not misreport that as "pending".
        self.assertIn("[string]$Token", release_status)
        self.assertIn("Authorization", release_status)
        self.assertIn("INDETERMINATE", release_status)

    def test_start_here_prepares_users_for_smartscreen(self) -> None:
        packaging = (REPO_ROOT / "scripts" / "package-portable.ps1").read_text(encoding="utf-8")
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("More info", packaging)
        self.assertIn("Run anyway", packaging)
        self.assertIn("Windows protected your PC", readme)

    def test_exe_requests_administrator_at_launch(self) -> None:
        packaging = (REPO_ROOT / "scripts" / "package-portable.ps1").read_text(encoding="utf-8")
        self.assertIn("-requireAdmin", packaging)

if __name__ == "__main__":
    unittest.main()