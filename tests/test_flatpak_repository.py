import base64
import configparser
import functools
import gzip
import http.server
import importlib.util
import io
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "de.magynhard.SystemView"
spec = importlib.util.spec_from_file_location("ftps_stage", ROOT / "scripts/stage-flatpak-ftps.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


@unittest.skipUnless(all(shutil.which(tool) for tool in ("flatpak", "ostree", "gpg")), "Flatpak repository tools required")
class FlatpakRepositoryTests(unittest.TestCase):
    def run_command(self, *args):
        return subprocess.run(args, check=True, text=True, capture_output=True)

    def export_fixture(self, directory, arch, version="a", release_version=None):
        app = directory / f"app-{arch}-{version}"
        files = app / "files/bin"
        files.mkdir(parents=True)
        (files / "fixture").write_text(f"fixture {version}\n")
        appstream = app / "files/share/app-info/xmls"
        appstream.mkdir(parents=True)
        release_version = release_version or f"1.0.{ord(version) - ord('a') + 1}"
        xml = (f'<components version="0.14" origin="test"><component type="desktop-application">'
               f'<id>{APP_ID}</id><name>System View</name><summary>Test</summary>'
               f'<releases><release version="{release_version}" date="2026-01-01"/></releases>'
               f'</component></components>')
        with gzip.open(appstream / f"{APP_ID}.xml.gz", "wb") as stream:
            stream.write(xml.encode())
        (app / "metadata").write_text(
            f"[Application]\nname={APP_ID}\nruntime=org.gnome.Platform/{arch}/51\n"
            f"sdk=org.gnome.Sdk/{arch}/51\ncommand=fixture\n"
        )
        repo = directory / f"source-{arch}-{version}"
        self.run_command("ostree", f"--repo={repo}", "init", "--mode=archive")
        self.run_command("flatpak", "build-finish", str(app))
        self.run_command("flatpak", "build-export", f"--arch={arch}",
                         f"--timestamp=2026-01-0{ord(version) - ord('a') + 1}T00:00:00Z",
                         str(repo), str(app), "master")
        return repo

    def stage_indexed_revision(self, source, destination):
        destination.mkdir(exist_ok=True)
        for name in ("objects", "summaries"):
            shutil.copytree(source / name, destination / name, dirs_exist_ok=True)
        if not (destination / "config").exists():
            shutil.copyfile(source / "config", destination / "config")
        else:
            self.assertEqual((source / "config").read_bytes(), (destination / "config").read_bytes())

    def activate_indexed_revision(self, source, destination):
        next_index = destination / "summary.idx.next"
        shutil.copyfile(source / "summary.idx", next_index)
        os.replace(next_index, destination / "summary.idx")

    def test_assembly_signs_both_architectures_and_embeds_public_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gpg_home = root / "gpg"
            gpg_home.mkdir(mode=0o700)
            self.run_command("gpg", "--homedir", str(gpg_home), "--batch", "--passphrase", "",
                             "--quick-generate-key", "Fixture <fixture@example.invalid>", "ed25519", "cert", "0")
            keys = self.run_command("gpg", "--homedir", str(gpg_home), "--with-colons", "--list-secret-keys").stdout
            fingerprint = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:"))
            self.run_command("gpg", "--homedir", str(gpg_home), "--batch", "--pinentry-mode", "loopback",
                             "--passphrase", "", "--quick-add-key", fingerprint, "ed25519", "sign", "2y")
            subkey = subprocess.run(["gpg", "--homedir", str(gpg_home), "--batch", "--pinentry-mode",
                                     "loopback", "--passphrase", "", "--export-secret-subkeys", fingerprint],
                                    check=True, capture_output=True).stdout
            ci_home = root / "ci-gpg"
            ci_home.mkdir(mode=0o700)
            subprocess.run(["gpg", "--homedir", str(ci_home), "--batch", "--import"],
                           input=subkey, check=True, capture_output=True)
            keys = self.run_command("gpg", "--homedir", str(ci_home), "--with-colons", "--list-secret-keys").stdout
            primary = next(line.split(":") for line in keys.splitlines() if line.startswith("sec:"))
            self.assertEqual(primary[14], "#")
            x86 = self.export_fixture(root, "x86_64")
            arm = self.export_fixture(root, "aarch64")
            output = root / "output"
            self.run_command("bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                             str(x86), str(arm), str(output), str(ci_home), fingerprint)

            descriptor = configparser.ConfigParser()
            descriptor.read(output / f"{APP_ID}.flatpakref")
            ref = descriptor["Flatpak Ref"]
            self.assertEqual(ref["Name"], APP_ID)
            self.assertEqual(ref["Branch"], "master")
            self.assertEqual(ref["Url"], "https://flatpak.magynhard.de/system-view/repo/")
            self.assertEqual(base64.b64decode(ref["GPGKey"]), (output / "public-key.gpg").read_bytes())
            for arch, source in (("x86_64", x86), ("aarch64", arm)):
                app_ref = f"app/{APP_ID}/{arch}/master"
                source_commit = self.run_command("ostree", f"--repo={source}", "rev-parse", app_ref).stdout
                target_commit = self.run_command("ostree", f"--repo={output / 'repo'}", "rev-parse", app_ref).stdout
                self.assertEqual(source_commit, target_commit)
            self.assertTrue((output / "repo/summary").is_file())
            self.assertTrue((output / "repo/summary.sig").is_file())
            public = root / "public"
            self.run_command("python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                             str(output), str(public), str(ci_home), fingerprint)
            self.assertEqual(staging.verify_publication(public), "1.0.1")
            with patch.dict(os.environ, {"FTPS_HOST": "host", "FTPS_PORT": "21",
                                        "FTPS_USERNAME": "user", "FTPS_PASSWORD": "password"}), \
                 patch("sys.argv", ["stage", str(public), "--confirm-activate",
                                    "--expected-current-index=none", "--release-version=2.0.0"]), \
                 patch("sys.stderr", io.StringIO()), patch.object(staging.ftplib, "FTP_TLS") as ftp:
                self.assertEqual(staging.main(), 1)
                ftp.assert_not_called()
            manifest = public / "publication.json"
            original = manifest.read_bytes()
            manifest.write_bytes(original.replace(b"1.0.1", b"9.0.0"))
            with self.assertRaisesRegex(ValueError, "signature"):
                staging.verify_publication(public)
            manifest.write_bytes(original)
            (public / "repo/summary.idx").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "metadata"):
                staging.verify_publication(public)
            different_arm = self.export_fixture(root, "aarch64", "b")
            mismatch = root / "mismatch"
            self.run_command("bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                             str(x86), str(different_arm), str(mismatch), str(ci_home), fingerprint)
            result = subprocess.run(["python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                                     str(mismatch), str(root / "mismatch-public"), str(ci_home), fingerprint],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("versions do not match", result.stderr)
            result = subprocess.run(["python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                                     str(output), str(public), str(ci_home), fingerprint], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            (output / "repo/summary.idx").unlink()
            result = subprocess.run(["python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                                     str(output), str(root / "invalid"), str(ci_home), fingerprint], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "invalid").exists())

            result = subprocess.run(["bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                                     str(x86), str(x86), str(root / "missing"), str(gpg_home), fingerprint],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "missing").exists())
            result = subprocess.run(["bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                                     str(x86), str(arm), str(output), str(gpg_home), fingerprint],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_install_update_and_reject_wrong_signing_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "keys"
            home.mkdir(mode=0o700)
            fingerprints = []
            for name in ("Good", "Wrong"):
                self.run_command("gpg", "--homedir", str(home), "--batch", "--passphrase", "",
                                 "--quick-generate-key", f"{name} <{name.lower()}@example.invalid>", "ed25519", "sign", "0")
                keys = self.run_command("gpg", "--homedir", str(home), "--with-colons",
                                        "--list-secret-keys", f"{name.lower()}@example.invalid").stdout
                fingerprints.append(next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:")))

            outputs = []
            for version, key in zip(("a", "b", "c"), (fingerprints[0], fingerprints[0], fingerprints[1])):
                x86 = self.export_fixture(root, "x86_64", version)
                arm = self.export_fixture(root, "aarch64", version)
                output = root / f"output-{version}"
                self.run_command("bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                                 str(x86), str(arm), str(output), str(home), key)
                public = root / f"public-{version}"
                self.run_command("python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                                 str(output), str(public), str(home), key)
                self.assertFalse((public / "repo/summary").exists())
                self.assertFalse((public / "repo/summary.sig").exists())
                outputs.append(public)

            site = root / "site"
            site.mkdir()
            self.stage_indexed_revision(outputs[0] / "repo", site / "repo")
            self.activate_indexed_revision(outputs[0] / "repo", site / "repo")
            handler = functools.partial(QuietHandler, directory=str(site))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                descriptor = (outputs[0] / f"{APP_ID}.flatpakref").read_text().replace(
                    "https://flatpak.magynhard.de/system-view/repo/", f"http://127.0.0.1:{server.server_port}/repo/"
                )
                ref_file = root / f"{APP_ID}.flatpakref"
                ref_file.write_text(descriptor)
                env = os.environ.copy()
                env.update(XDG_DATA_HOME=str(root / "data"), XDG_CONFIG_HOME=str(root / "config"),
                           XDG_CACHE_HOME=str(root / "cache"), LC_ALL="C")
                def flatpak(*args, check=True):
                    return subprocess.run(["flatpak", *args], env=env, text=True, capture_output=True, check=check)

                flatpak("install", "--user", "--noninteractive", "--no-deps", str(ref_file))
                self.assertEqual(flatpak("info", "--user", "--show-origin", APP_ID).stdout.strip(), "system-view")
                first = flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip()
                self.stage_indexed_revision(outputs[1] / "repo", site / "repo")
                flatpak("update", "--user", "--noninteractive", "--no-deps", APP_ID)
                self.assertEqual(first, flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip())
                self.activate_indexed_revision(outputs[1] / "repo", site / "repo")
                flatpak("update", "--user", "--noninteractive", "--no-deps", APP_ID)
                second = flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip()
                self.assertNotEqual(first, second)
                self.stage_indexed_revision(outputs[2] / "repo", site / "repo")
                self.activate_indexed_revision(outputs[2] / "repo", site / "repo")
                rejected = flatpak("update", "--user", "--noninteractive", "--no-deps", APP_ID, check=False)
                self.assertEqual(second, flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip())
                self.assertTrue(rejected.returncode != 0 or "Warning" in rejected.stderr,
                                rejected.stdout + rejected.stderr)
                verifier = root / "verifier"
                self.run_command("ostree", f"--repo={verifier}", "init", "--mode=archive")
                self.run_command("ostree", f"--repo={verifier}", "remote", "add",
                                 f"--gpg-import={root / 'output-a/public-key.gpg'}", "test",
                                 (outputs[2] / "repo").as_uri())
                result = subprocess.run(["ostree", f"--repo={verifier}", "pull-local", "--untrusted",
                                         "--gpg-verify", "--remote=test", str(outputs[2] / "repo"),
                                         f"app/{APP_ID}/x86_64/master"], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            finally:
                server.shutdown()
                thread.join()
                server.server_close()

    @unittest.skipUnless(os.environ.get("SYSTEM_VIEW_TEST_FLATPAK_BUILD"),
                         "Set SYSTEM_VIEW_TEST_FLATPAK_BUILD to a finalized native Flatpak build")
    def test_real_x86_build_installs_and_updates(self):
        build = Path(os.environ["SYSTEM_VIEW_TEST_FLATPAK_BUILD"]).resolve()
        self.assertTrue((build / "metadata").is_file())
        self.assertTrue((build / "files/bin/system-view").is_file())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "keys"
            home.mkdir(mode=0o700)
            self.run_command("gpg", "--homedir", str(home), "--batch", "--passphrase", "",
                             "--quick-generate-key", "Test <test@example.invalid>", "ed25519", "sign", "0")
            keys = self.run_command("gpg", "--homedir", str(home), "--with-colons", "--list-secret-keys").stdout
            fingerprint = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:"))
            outputs = []
            actual_version = self.run_command("python3", str(ROOT / "scripts/packaging.py"), "version").stdout.strip()
            arm = self.export_fixture(root, "aarch64", release_version=actual_version)
            for version in ("a", "b"):
                source = root / f"real-{version}"
                self.run_command("ostree", f"--repo={source}", "init", "--mode=archive")
                self.run_command("flatpak", "build-export", "--arch=x86_64",
                                 f"--timestamp=2026-01-0{1 if version == 'a' else 2}T00:00:00Z",
                                 str(source), str(build), "master")
                output = root / f"output-{version}"
                self.run_command("bash", str(ROOT / "scripts/assemble-flatpak-repo.sh"),
                                 str(source), str(arm), str(output), str(home), fingerprint)
                xml = self.run_command("ostree", f"--repo={output / 'repo'}", "cat",
                                       "appstream2/x86_64", "/appstream.xml").stdout
                self.assertIn(APP_ID, xml)
                icon = subprocess.run(["ostree", f"--repo={output / 'repo'}", "cat",
                                       "appstream2/x86_64", f"/icons/128x128/{APP_ID}.png"],
                                      check=True, capture_output=True).stdout
                self.assertTrue(icon.startswith(b"\x89PNG\r\n\x1a\n"))
                public = root / f"public-{version}"
                self.run_command("python3", str(ROOT / "scripts/prepare-flatpak-publication.py"),
                                 str(output), str(public), str(home), fingerprint)
                outputs.append(public)

            site = root / "site"
            site.mkdir()
            self.stage_indexed_revision(outputs[0] / "repo", site / "repo")
            self.activate_indexed_revision(outputs[0] / "repo", site / "repo")
            handler = functools.partial(QuietHandler, directory=str(site))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                ref = root / f"{APP_ID}.flatpakref"
                ref.write_text((outputs[0] / ref.name).read_text().replace(
                    "https://flatpak.magynhard.de/system-view/repo/", f"http://127.0.0.1:{server.server_port}/repo/"))
                env = os.environ.copy()
                env.update(XDG_DATA_HOME=str(root / "data"), XDG_CONFIG_HOME=str(root / "config"),
                           XDG_CACHE_HOME=str(root / "cache"), LC_ALL="C")
                def flatpak(*args):
                    return subprocess.run(["flatpak", *args], env=env, text=True, capture_output=True, check=True)

                flatpak("install", "--user", "--noninteractive", "--no-deps", str(ref))
                first = flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip()
                self.assertEqual(flatpak("info", "--user", "--show-origin", APP_ID).stdout.strip(), "system-view")
                self.stage_indexed_revision(outputs[1] / "repo", site / "repo")
                self.activate_indexed_revision(outputs[1] / "repo", site / "repo")
                flatpak("update", "--user", "--noninteractive", "--no-deps", APP_ID)
                second = flatpak("info", "--user", "--show-commit", APP_ID).stdout.strip()
                self.assertNotEqual(first, second)
            finally:
                server.shutdown()
                thread.join()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
