import hashlib
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("release_guard", "scripts/check-flatpak-release.py")
index = load("current_index", "scripts/current-flatpak-index.py")


class FlatpakReleaseTests(unittest.TestCase):
    def test_latest_release_checks_id_tag_and_stable_status(self):
        def response(data):
            return io.BytesIO(json.dumps(data).encode())

        good = {"id": 42, "tag_name": "1.2.3", "draft": False, "prerelease": False}
        with patch.object(release.urllib.request, "build_opener", return_value=MagicMock(open=MagicMock(return_value=response(good)))):
            release.check("https://api.github.com", "owner/repo", "token", "1.2.3", "42")
        for data in ({**good, "id": 43}, {**good, "tag_name": "1.2.4"},
                     {**good, "draft": True}, {**good, "prerelease": True}):
            with patch.object(release.urllib.request, "build_opener", return_value=MagicMock(open=MagicMock(return_value=response(data)))):
                with self.assertRaises(ValueError):
                    release.check("https://api.github.com", "owner/repo", "token", "1.2.3", "42")
        with self.assertRaises(ValueError):
            release.check("https://api.github.com", "owner/repo", "token", "v1.2.3", "42")
        with self.assertRaises(ValueError):
            release.check("http://api.github.com", "owner/repo", "token", "1.2.3", "42")

    def test_public_index_requires_verified_https_and_expected_status(self):
        class Response(io.BytesIO):
            def __init__(self, status, data):
                super().__init__(data)
                self.status = status

        class Connection:
            def __init__(self, status, data):
                self.response = Response(status, data)
            def request(self, *args, **kwargs):
                pass
            def getresponse(self):
                return self.response
            def close(self):
                pass

        with patch.object(index.http.client, "HTTPSConnection", return_value=Connection(200, b"test")) as factory:
            self.assertEqual(index.current_index(), hashlib.sha256(b"test").hexdigest())
            self.assertTrue(factory.call_args.kwargs["context"].check_hostname)
        with patch.object(index.http.client, "HTTPSConnection", return_value=Connection(404, b"")):
            self.assertEqual(index.current_index(), "none")
        for status, data in ((302, b""), (500, b""), (200, b"x" * (5 * 1024 * 1024 + 1))):
            with patch.object(index.http.client, "HTTPSConnection", return_value=Connection(status, data)):
                with self.assertRaises(ValueError):
                    index.current_index()


if __name__ == "__main__":
    unittest.main()
