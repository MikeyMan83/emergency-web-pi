import importlib.util
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("device_config", REPO_ROOT / "scripts" / "device_config.py")
device_config = importlib.util.module_from_spec(spec)
sys.modules["device_config"] = device_config
spec.loader.exec_module(device_config)


class DeviceConfigTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.zim = root / "zim"
        self.nm = root / "nm"
        self.env = root / ".env"
        self.zim.mkdir()
        self.env.write_text("AP_SSID=default-ssid\nAP_ADDRESS=10.42.0.1/24\nAP_COUNTRY_CODE=DE\n", encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def run_apply(self, mounted=True):
        return device_config.apply(self.zim, self.env, self.nm, mounted)

    def write_config(self, ap):
        (self.zim / "device-config.json").write_text(json.dumps({"schemaVersion": 1, "ap": ap}), encoding="utf-8")

    def test_config_is_applied_and_plaintext_removed(self):
        self.write_config({"ssid": "Card-42", "password": "correct horse 9"})
        self.assertEqual(self.run_apply(), "configured")
        profile = (self.nm / "pi-kiwix-ap.nmconnection").read_text(encoding="utf-8")
        self.assertIn("ssid=Card-42\n", profile)
        self.assertIn("psk=correct horse 9\n", profile)
        self.assertIn("country=DE\n", profile)
        self.assertIn("address1=10.42.0.1/24\n", profile)
        self.assertFalse((self.zim / "device-config.json").exists())
        self.assertFalse((self.zim / "wifi-credentials.txt").exists())

    def test_profile_is_root_only(self):
        self.write_config({"ssid": "Card-42", "password": "password123"})
        self.run_apply()
        mode = stat.S_IMODE((self.nm / "pi-kiwix-ap.nmconnection").stat().st_mode)
        if sys.platform != "win32":
            self.assertEqual(mode, 0o600)

    def test_country_override(self):
        self.write_config({"ssid": "x", "password": "password123", "countryCode": "US"})
        self.run_apply()
        self.assertIn("country=US\n", (self.nm / "pi-kiwix-ap.nmconnection").read_text(encoding="utf-8"))

    def test_absent_config_generates_password_and_credentials_file(self):
        self.assertEqual(self.run_apply(), "generated")
        profile = (self.nm / "pi-kiwix-ap.nmconnection").read_text(encoding="utf-8")
        creds = (self.zim / "wifi-credentials.txt").read_text(encoding="utf-8")
        password = [l for l in profile.splitlines() if l.startswith("psk=")][0][4:]
        self.assertEqual(len(password), 16)
        self.assertIn(f"Password: {password}", creds)
        self.assertIn("SSID: default-ssid", creds)

    def test_existing_profile_is_kept_on_later_boots(self):
        self.write_config({"ssid": "Card-42", "password": "password123"})
        self.run_apply()
        before = (self.nm / "pi-kiwix-ap.nmconnection").read_text(encoding="utf-8")
        self.assertEqual(self.run_apply(), "unchanged")
        self.assertEqual(before, (self.nm / "pi-kiwix-ap.nmconnection").read_text(encoding="utf-8"))

    def test_unmounted_zimdata_still_yields_an_ap_without_credentials_file(self):
        self.assertEqual(self.run_apply(mounted=False), "generated")
        self.assertTrue((self.nm / "pi-kiwix-ap.nmconnection").exists())
        self.assertFalse((self.zim / "wifi-credentials.txt").exists())

    def test_invalid_values_are_rejected(self):
        for ap in (
            {"ssid": "", "password": "password123"},
            {"ssid": "a" * 33, "password": "password123"},
            {"ssid": "ok\nmode=ap", "password": "password123"},
            {"ssid": "ok", "password": "short"},
            {"ssid": "ok", "password": "line\nbreak1234"},
            {"ssid": "ok", "password": "password123", "countryCode": "nl"},
        ):
            self.write_config(ap)
            with self.assertRaises(device_config.DeviceConfigError, msg=str(ap)):
                self.run_apply()

    def test_main_falls_back_and_deletes_bad_config(self):
        self.write_config({"ssid": "ok", "password": "short"})
        # os.path.ismount is False for a temp dir, so mounted-only paths are covered via apply() above.
        rc = device_config.main(["--zim-dir", str(self.zim), "--env-file", str(self.env), "--nm-dir", str(self.nm)])
        self.assertEqual(rc, 0)
        self.assertTrue((self.nm / "pi-kiwix-ap.nmconnection").exists())


if __name__ == "__main__":
    unittest.main()
