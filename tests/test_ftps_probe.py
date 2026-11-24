import ftplib
import importlib.util
import io
import ssl
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ftps_probe", ROOT / "scripts/probe-ftps.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FtpsProbeTests(unittest.TestCase):
    def test_configuration_requires_all_secrets_and_valid_port(self):
        with self.assertRaisesRegex(ValueError, "FTPS_HOST"):
            probe.configuration({})
        settings = {"FTPS_HOST": "host", "FTPS_PORT": "21",
                    "FTPS_USERNAME": "user", "FTPS_PASSWORD": "password"}
        self.assertEqual(probe.configuration(settings), ("host", 21, "user", "password"))
        for port in ("0", "65536", "invalid"):
            with self.assertRaisesRegex(ValueError, "FTPS_PORT"):
                probe.configuration({**settings, "FTPS_PORT": port})

    def test_probe_uses_verified_tls_and_limits_changes_to_test_directory(self):
        ftp = MagicMock()
        ftp.delete.side_effect = [ftplib.error_perm("550 missing"), None]
        with patch.object(probe.ftplib, "FTP_TLS", return_value=ftp) as factory, \
             patch.object(probe, "fetch_https") as fetch:
            probe.probe(("host", 21, "user", "password"))
        context = factory.call_args.kwargs["context"]
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        ftp.connect.assert_called_once_with("host", 21)
        ftp.login.assert_called_once_with("user", "password")
        ftp.prot_p.assert_called_once()
        directory = ftp.mkd.call_args.args[0]
        self.assertRegex(directory, r"^system-view-ftps-test-[0-9a-f]{32}$")
        self.assertEqual([call.args[0] for call in ftp.cwd.call_args_list], [directory, ".."])
        ftp.rename.assert_called_once_with("test.next", "test")
        ftp.rmd.assert_called_once_with(directory)
        self.assertEqual(fetch.call_count, 2)
        self.assertTrue(fetch.call_args_list[0].args[0].startswith(f"/{directory}/test?"))

    def test_failed_replacement_does_not_report_success(self):
        ftp = MagicMock()
        ftp.rename.side_effect = ftplib.error_perm("550 rename denied")
        with patch.object(probe.ftplib, "FTP_TLS", return_value=ftp), \
             patch.object(probe, "fetch_https"):
            with self.assertRaises(ftplib.error_perm):
                probe.probe(("host", 21, "user", "password"))
        ftp.rmd.assert_called_once()

    def test_cleanup_failure_is_an_error(self):
        ftp = MagicMock()
        ftp.rmd.side_effect = ftplib.error_perm("550 directory not empty")
        with patch.object(probe.ftplib, "FTP_TLS", return_value=ftp), \
             patch.object(probe, "fetch_https"), \
             patch("sys.stderr"):
            with self.assertRaisesRegex(RuntimeError, "cleanup"):
                probe.probe(("host", 21, "user", "password"))

    def test_tls_errors_do_not_disclose_connection_details(self):
        error = ssl.SSLCertVerificationError("private-host-name")
        output = io.StringIO()
        with patch("sys.argv", ["probe", "--confirm-test-upload"]), \
             patch.object(probe, "configuration", return_value=("host", 21, "user", "password")), \
             patch.object(probe, "probe", side_effect=error), patch("sys.stderr", output):
            self.assertEqual(probe.main(), 1)
        self.assertNotIn("private-host-name", output.getvalue())


if __name__ == "__main__":
    unittest.main()
