#!/usr/bin/env python3
"""Automated tests for Pebble Manager CLI, PBW inspector, and Rebble client."""

import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
import zipfile

# Add parent directory to path to import pebble_manager
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

from pebble_manager import PBWPackage, RebbleStore, PebbleController


class TestPBWPackage(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.pbw_path = pathlib.Path(self.temp_dir.name) / "test_app.pbw"

        # Create a valid synthetic .pbw file
        appinfo = {
            "uuid": "4b0a0f75-ef47-4fc4-a75a-992095ef7e6d",
            "shortName": "TestApp",
            "longName": "Test Application",
            "companyName": "TestCorp",
            "versionLabel": "1.2.3",
            "watchapp": {
                "watchface": True
            },
            "targetPlatforms": ["diorite", "basalt"]
        }
        with zipfile.ZipFile(self.pbw_path, "w") as z:
            z.writestr("appinfo.json", json.dumps(appinfo))
            z.writestr("pebble-app.bin", b"\x00" * 64)
            z.writestr("diorite/app.bin", b"\x00" * 32)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_inspect_valid_pbw(self):
        meta = PBWPackage.inspect(self.pbw_path)
        self.assertEqual(meta["uuid"], "4b0a0f75-ef47-4fc4-a75a-992095ef7e6d")
        self.assertEqual(meta["short_name"], "TestApp")
        self.assertEqual(meta["long_name"], "Test Application")
        self.assertEqual(meta["company"], "TestCorp")
        self.assertEqual(meta["version"], "1.2.3")
        self.assertTrue(meta["is_watchface"])
        self.assertIn("diorite", meta["target_platforms"])
        self.assertGreater(meta["file_size"], 0)

    def test_inspect_nonexistent_file(self):
        with self.assertRaises(FileNotFoundError):
            PBWPackage.inspect("/nonexistent/path/foo.pbw")

    def test_inspect_invalid_zip(self):
        corrupt_path = pathlib.Path(self.temp_dir.name) / "corrupt.pbw"
        with open(corrupt_path, "wb") as f:
            f.write(b"not a zip file")
        with self.assertRaises(ValueError):
            PBWPackage.inspect(corrupt_path)


class TestRebbleStore(unittest.TestCase):
    def test_resolve_local_file(self):
        with tempfile.NamedTemporaryFile(suffix=".pbw", delete=False) as f:
            f.write(b"fake pbw")
            temp_name = f.name
        try:
            url, filename = RebbleStore.resolve_pbw_url(temp_name)
            self.assertEqual(url, temp_name)
            self.assertEqual(filename, os.path.basename(temp_name))
        finally:
            os.unlink(temp_name)

    def test_resolve_direct_url(self):
        target = "https://assets.rebble.io/pbw/sample-watchface.pbw"
        url, filename = RebbleStore.resolve_pbw_url(target)
        self.assertEqual(url, target)
        self.assertEqual(filename, "sample-watchface.pbw")

    def test_resolve_direct_url_without_extension(self):
        target = "https://example.com/download/app"
        url, filename = RebbleStore.resolve_pbw_url(target)
        self.assertEqual(url, target)
        self.assertEqual(filename, "app.pbw")


class TestPebbleControllerRegex(unittest.TestCase):
    def test_mac_normalization(self):
        mac = "00_18_33_aa_bb_cc"
        normalized = mac.replace("_", ":").upper()
        self.assertEqual(normalized, "00:18:33:AA:BB:CC")


class TestPebbleManagerHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import threading
        import urllib.request
        from http.server import HTTPServer
        from pebble_manager import PebbleManagerRequestHandler

        cls.httpd = HTTPServer(("127.0.0.1", 0), PebbleManagerRequestHandler)
        cls.port = cls.httpd.server_port
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def test_get_dashboard(self):
        import urllib.request
        url = f"http://127.0.0.1:{self.port}/"
        with urllib.request.urlopen(url) as resp:
            self.assertEqual(resp.status, 200)
            content = resp.read().decode("utf-8")
            self.assertIn("Pebble Manager", content)

    def test_api_status(self):
        import urllib.request
        url = f"http://127.0.0.1:{self.port}/api/status"
        with urllib.request.urlopen(url) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode("utf-8"))
            self.assertIn("daemon_running", data)
            self.assertIn("watches", data)

    def test_api_search_empty(self):
        import urllib.request
        url = f"http://127.0.0.1:{self.port}/api/search"
        with urllib.request.urlopen(url) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode("utf-8"))
            self.assertEqual(data.get("results"), [])


if __name__ == "__main__":
    unittest.main()
