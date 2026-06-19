import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("usage_api", ROOT / "src" / "usage_api.py")
usage_api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(usage_api)


class UsageApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data_path = pathlib.Path(self.temp.name) / "usage.json"
        self.snapshot = {
            "schema_version": 1,
            "observed_at": "2026-06-19T12:00:00+09:00",
            "providers": {"codex": {"available": True}, "claude": {"available": True}},
        }
        self.data_path.write_text(json.dumps(self.snapshot), encoding="utf-8")
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0), usage_api.make_handler(str(self.data_path))
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def get_json(self, path):
        with urllib.request.urlopen(self.base_url + path, timeout=2) as response:
            return response.status, json.load(response)

    def test_usage_endpoint(self):
        status, body = self.get_json("/api/v1/usage")
        self.assertEqual(200, status)
        self.assertEqual(1, body["schema_version"])
        self.assertTrue(body["providers"]["codex"]["available"])

    def test_health_endpoint(self):
        status, body = self.get_json("/health")
        self.assertEqual(200, status)
        self.assertEqual("ok", body["status"])
        self.assertTrue(body["data_available"])


if __name__ == "__main__":
    unittest.main()
