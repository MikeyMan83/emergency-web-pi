from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
STATUS_WEB_PATH = REPO_ROOT / "scripts" / "status-web.py"
SPEC = importlib.util.spec_from_file_location("status_web", STATUS_WEB_PATH)
assert SPEC and SPEC.loader
status_web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(status_web)


class StatusWebTests(unittest.TestCase):
    def make_handler(self, zim_data_dir: pathlib.Path) -> status_web.StatusHandler:
        handler = object.__new__(status_web.StatusHandler)
        handler.zim_data_dir = zim_data_dir
        return handler

    def test_pending_content_reports_progress_and_is_not_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            zim_data_dir = pathlib.Path(temp_dir)
            (zim_data_dir / "zimlist.txt").write_text("one.zim\ntwo.zim\n", encoding="utf-8")
            (zim_data_dir / ".content-install-pending").touch()
            (zim_data_dir / "one.zim").write_bytes(b"zim")
            (zim_data_dir / "library.xml").write_text("indexed", encoding="utf-8")

            with patch.object(status_web, "content_storage_mounted", return_value=True), patch.object(status_web, "service_active", return_value=True):
                status = self.make_handler(zim_data_dir)._status()

        self.assertTrue(status["contentInstallPending"])
        self.assertEqual(2, status["expectedZimCount"])
        self.assertEqual(1, status["zimCount"])
        self.assertEqual(50, status["contentProgressPercent"])
        self.assertFalse(status["ready"])

    def test_complete_indexed_content_reports_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            zim_data_dir = pathlib.Path(temp_dir)
            (zim_data_dir / "zimlist.txt").write_text("one.zim\n", encoding="utf-8")
            (zim_data_dir / "one.zim").write_bytes(b"zim")
            (zim_data_dir / "library.xml").write_text("indexed", encoding="utf-8")

            with patch.object(status_web, "content_storage_mounted", return_value=True), patch.object(status_web, "service_active", return_value=True):
                status = self.make_handler(zim_data_dir)._status()

        self.assertFalse(status["contentInstallPending"])
        self.assertEqual(100, status["contentProgressPercent"])
        self.assertTrue(status["ready"])


if __name__ == "__main__":
    unittest.main()