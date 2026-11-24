import importlib.util
import json
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("packaging_inputs", ROOT / "scripts/packaging.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def test_local_env_is_excluded_from_packaging(self):
        for name in (".env", ".env.local"):
            self.assertEqual(subprocess.run(
                ["git", "check-ignore", "-q", name], cwd=ROOT
            ).returncode, 0)
        dockerignore = (ROOT / ".dockerignore").read_text().splitlines()
        self.assertIn(".env", dockerignore)
        self.assertIn(".env.*", dockerignore)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            root.mkdir()
            for name in (".env", ".env.local", "safe.txt"):
                (root / name).write_text("test")
            from unittest.mock import patch
            with patch.object(packaging, "ROOT", root), patch.object(packaging, "verify"):
                destination = Path(directory) / "output"
                packaging.flatpak_manifest(destination)
            snapshot = destination / "source"
            self.assertFalse((snapshot / ".env").exists())
            self.assertFalse((snapshot / ".env.local").exists())
            self.assertTrue((snapshot / "safe.txt").exists())

    def test_shard_pins_and_appstream_version_match(self):
        self.assertRegex(packaging.verify(), r"^\d+\.\d+\.\d+(?:[-+].+)?$")

    def test_appstream_references_the_project_screenshot(self):
        metadata = ET.parse(ROOT / "data/de.magynhard.SystemView.metainfo.xml")
        screenshot = metadata.find("./screenshots/screenshot[@type='default']/image")
        self.assertIsNotNone(screenshot)
        self.assertEqual(screenshot.text, "https://raw.githubusercontent.com/magynhard/system-view.cr/master/doc/screenshot.png")
        self.assertTrue((ROOT / "doc/screenshot.png").is_file())

    def test_downloads_have_sha256_and_https(self):
        sources = [packaging.PINS[name] for name in ("gc", "mesa_demos", "vulkan_tools", "linuxdeploy", "gtk_plugin", "appimage_runtime")]
        sources += [packaging.PINS["crystal"][arch] for arch in ("x86_64", "aarch64")]
        for source in sources:
            self.assertRegex(source["sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(source["url"].startswith("https://"))

    def test_lock_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "shard.lock").write_text((ROOT / "shard.lock").read_text().replace("0.26.0", "0.25.0"))
            (root / "shard.yml").write_text((ROOT / "shard.yml").read_text())
            with self.assertRaisesRegex(ValueError, "gi-crystal"):
                packaging.verify(root)

    def test_manifest_has_read_only_host_access_and_offline_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            packaging.flatpak_manifest(Path(directory))
            manifest = json.loads((Path(directory) / f"{packaging.APP_ID}.json").read_text())
            self.assertEqual(manifest["command"], "system-view")
            permissions = manifest["finish-args"]
            self.assertIn("--filesystem=host-root:ro", permissions)
            self.assertIn("--filesystem=/run/udev:ro", permissions)
            self.assertIn("--talk-name=org.freedesktop.Flatpak", permissions)
            self.assertIn("--talk-name=org.gnome.Shell", permissions)
            self.assertIn("--talk-name=org.gnome.Mutter.DisplayConfig", permissions)
            self.assertIn("--talk-name=org.gnome.Settings", permissions)
            self.assertIn("--system-talk-name=org.freedesktop.NetworkManager", permissions)
            self.assertIn("--system-talk-name=org.bluez", permissions)
            self.assertIn("--system-talk-name=org.freedesktop.UDisks2", permissions)
            self.assertIn("--socket=pulseaudio", permissions)
            self.assertIn("--socket=cups", permissions)
            self.assertIn("--socket=x11", permissions)
            self.assertIn("--require-version=1.17.0", permissions)
            for permission in ("--device=all", "--share=network", "--socket=system-bus"):
                self.assertNotIn(permission, permissions)
            self.assertFalse(manifest["separate-locales"])
            module = manifest["modules"][-1]
            self.assertEqual([item["name"] for item in manifest["modules"]], ["bdw-gc", "glxinfo", "vulkaninfo", "system-view"])
            self.assertEqual(module["name"], "system-view")
            git_sources = [source for source in module["sources"] if source["type"] == "git"]
            self.assertEqual(len(git_sources), len(packaging.PINS["shards"]))
            for source in git_sources:
                self.assertRegex(source["commit"], r"^[a-f0-9]{40}$")
            snapshot = Path(module["sources"][0]["path"])
            for name in (".git", "lib", "bin", "build", "dist"):
                self.assertFalse((snapshot / name).exists(), name)

    def test_appimage_preserves_system_theme_and_display_backend(self):
        hook = (ROOT / "packaging/appimage/gtk-runtime.sh").read_text()
        self.assertNotRegex(hook, r"(?m)^export (GTK_THEME|GDK_BACKEND)=")
        self.assertIn("GIO_MODULE_DIR", hook)

    def test_release_upload_waits_for_both_read_only_builds(self):
        import yaml

        workflow = yaml.load((ROOT / ".github/workflows/linux-packages.yml").read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(workflow["permissions"]["contents"], "read")
        upload = workflow["jobs"]["release-assets"]
        self.assertEqual(upload["if"], "github.event_name == 'release'")
        self.assertEqual(upload["permissions"]["contents"], "write")
        self.assertCountEqual(upload["needs"], ["appimage", "flatpak"])
        self.assertEqual(workflow["on"]["release"]["types"], ["published"])
        flatpak = workflow["jobs"]["flatpak"]
        self.assertCountEqual(flatpak["strategy"]["matrix"]["include"], [
            {"arch": "x86_64", "runner": "ubuntu-24.04"},
            {"arch": "aarch64", "runner": "ubuntu-24.04-arm"},
        ])
        self.assertIn("flatpak-${{ matrix.arch }}", str(flatpak["steps"]))
        self.assertIn("aarch64.flatpak.sha256", upload["steps"][-1]["run"])
        self.assertIn("ostree-${{ matrix.arch }}", str(flatpak["steps"]))
        self.assertEqual(workflow["jobs"]["flatpak-repository-test"]["needs"], ["flatpak"])
        self.assertIn("appstream2/$arch", str(workflow["jobs"]["flatpak-repository-test"]["steps"]))
        patterns = [step.get("with", {}).get("pattern") for step in upload["steps"]]
        self.assertIn("appimage-*", patterns)
        self.assertIn("flatpak-*", patterns)
        self.assertNotIn("ostree-*", patterns)
        publish = workflow["jobs"]["flatpak-publish"]
        images = [workflow["jobs"][name]["container"]["image"]
                  for name in ("flatpak", "flatpak-repository-test", "flatpak-publish")]
        self.assertEqual(len(set(images)), 1)
        self.assertRegex(images[0], r"@sha256:[a-f0-9]{64}$")
        self.assertIn("vars.FLATPAK_PUBLISH_ENABLED == 'true'", publish["if"])
        self.assertIn("github.event.release.prerelease == false", publish["if"])
        self.assertEqual(publish["environment"], "flatpak-production")
        self.assertCountEqual(publish["needs"], ["flatpak-repository-test", "release-assets"])
        self.assertEqual(publish["concurrency"]["cancel-in-progress"], "false")
        sign = next(step for step in publish["steps"] if step.get("name") == "Sign release repository")
        deploy = next(step for step in publish["steps"] if step.get("name") == "Stage and activate release")
        self.assertIn("FLATPAK_SIGNING_KEY", str(sign["env"]))
        self.assertNotIn("FTPS_PASSWORD", str(sign["env"]))
        self.assertIn("FTPS_PASSWORD", str(deploy["env"]))
        self.assertNotIn("FLATPAK_SIGNING_KEY", str(deploy["env"]))
        self.assertIn("check-flatpak-release.py", deploy["run"])
        self.assertIn("current-flatpak-index.py", deploy["run"])


if __name__ == "__main__":
    unittest.main()
