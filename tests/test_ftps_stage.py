import ftplib
import hashlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ftps_stage", ROOT / "scripts/stage-flatpak-ftps.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class FakeFtp:
    def __init__(self):
        self.cwd_path = PurePosixPath("/")
        self.directories = {PurePosixPath("/")}
        self.files = {}

    def cwd(self, path):
        target = PurePosixPath("/") if path == "/" else self.cwd_path / path
        if target not in self.directories:
            raise ftplib.error_perm("550 missing")
        self.cwd_path = target

    def mlsd(self):
        result = [(p.name, {"type": "dir"}) for p in self.directories if p.parent == self.cwd_path and p != self.cwd_path]
        result += [(p.name, {"type": "file"}) for p in self.files if p.parent == self.cwd_path]
        return iter(result)

    def mkd(self, name):
        target = self.cwd_path / name
        if target in self.directories or target in self.files:
            raise ftplib.error_perm("550 exists")
        self.directories.add(target)

    def rmd(self, name):
        self.directories.remove(self.cwd_path / name)

    def storbinary(self, command, stream):
        self.files[self.cwd_path / command.removeprefix("STOR ")] = stream.read()

    def retrbinary(self, command, callback):
        callback(self.files[self.cwd_path / command.removeprefix("RETR ")])

    def rename(self, source, target):
        self.files[self.cwd_path / target] = self.files.pop(self.cwd_path / source)

    def delete(self, name):
        del self.files[self.cwd_path / name]


class FtpsStageTests(unittest.TestCase):
    def publication(self, root):
        repo = root / "repo"
        (repo / "objects/ab").mkdir(parents=True)
        (repo / "summaries").mkdir()
        (repo / "config").write_bytes(b"config")
        (repo / "objects/ab/object.filez").write_bytes(b"object")
        (repo / "summaries/index.idx.sig").write_bytes(b"signature")
        (repo / "summary.idx").write_bytes(b"new-index")
        (root / "de.magynhard.SystemView.flatpakref").write_bytes(b"descriptor")
        return root

    def test_stages_only_data_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            ftp.directories.add(PurePosixPath("/repo"))
            ftp.files[PurePosixPath("/repo/summary.idx")] = b"old-index"
            ftp.files[PurePosixPath("/de.magynhard.SystemView.flatpakref")] = b"old-descriptor"
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)
            staging.stage(ftp, public, files)
            self.assertEqual(ftp.files[PurePosixPath("/repo/summary.idx")], b"old-index")
            self.assertEqual(ftp.files[PurePosixPath("/de.magynhard.SystemView.flatpakref")], b"old-descriptor")
            self.assertEqual(ftp.files[PurePosixPath("/repo/objects/ab/object.filez")], b"object")
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_conflicting_remote_object_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            ftp.directories.update(map(PurePosixPath, ("/repo", "/repo/objects", "/repo/objects/ab")))
            target = PurePosixPath("/repo/objects/ab/object.filez")
            ftp.files[target] = b"different"
            with self.assertRaisesRegex(RuntimeError, "differs"):
                staging.stage(ftp, public, staging.publication_files(public))
            self.assertEqual(ftp.files[target], b"different")
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_existing_lock_blocks_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            ftp.directories.add(PurePosixPath("/") / staging.LOCK)
            with self.assertRaises(ftplib.error_perm):
                staging.stage(ftp, public, staging.publication_files(public))
            self.assertEqual(ftp.files, {})

    def test_failed_upload_verification_removes_temporary_file(self):
        class CorruptingFtp(FakeFtp):
            def storbinary(self, command, stream):
                super().storbinary(command, io.BytesIO(b"corrupted"))

        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = CorruptingFtp()
            with self.assertRaisesRegex(RuntimeError, "verification"):
                staging.stage(ftp, public, staging.publication_files(public))
            self.assertFalse(any(p.name.startswith("system-view-upload-") for p in ftp.files))
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_missing_index_fails_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            (public / "repo/summary.idx").unlink()
            with self.assertRaisesRegex(ValueError, "metadata"):
                staging.publication_files(public)

    def test_activation_checks_https_before_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)

            def verify(path, digest, size):
                self.assertEqual(len(ftp.files[PurePosixPath(path)]), size)
                self.assertEqual(hashlib.sha256(ftp.files[PurePosixPath(path)]).digest(), digest)

            with patch.object(staging, "verify_https", side_effect=verify):
                staging.activate(ftp, public, files, "none", "1.0.0")
            self.assertEqual(ftp.files[PurePosixPath("/repo/summary.idx")], b"new-index")
            self.assertEqual(ftp.files[PurePosixPath("/") / staging.DESCRIPTOR], b"descriptor")
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_activation_refuses_changed_index_or_descriptor(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)
            index = PurePosixPath("/repo/summary.idx")
            ftp.files[index] = b"old-index"
            with patch.object(staging, "verify_https"):
                with self.assertRaisesRegex(RuntimeError, "expected index"):
                    staging.activate(ftp, public, files, "none", "1.0.0")
                self.assertEqual(ftp.files[index], b"old-index")
                ftp.files[PurePosixPath("/") / staging.DESCRIPTOR] = b"another-key"
                old_hash = hashlib.sha256(b"old-index").hexdigest()
                with self.assertRaisesRegex(RuntimeError, "descriptor differs"):
                    staging.activate(ftp, public, files, old_hash, "1.0.0")
            self.assertEqual(ftp.files[index], b"old-index")
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_https_verification_failure_does_not_activate(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)
            with patch.object(staging, "verify_https", side_effect=RuntimeError("mismatch")):
                with self.assertRaisesRegex(RuntimeError, "mismatch"):
                    staging.activate(ftp, public, files, "none", "1.0.0")
            self.assertNotIn(PurePosixPath("/repo/summary.idx"), ftp.files)
            self.assertNotIn(PurePosixPath("/") / staging.DESCRIPTOR, ftp.files)
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_index_may_be_active_if_https_fails_after_rename(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)

            def verify(path, digest, size):
                if path == "/repo/summary.idx":
                    raise RuntimeError("index not yet visible")

            with patch.object(staging, "verify_https", side_effect=verify):
                with self.assertRaisesRegex(RuntimeError, "not yet visible"):
                    staging.activate(ftp, public, files, "none", "1.0.0")
            self.assertEqual(ftp.files[PurePosixPath("/repo/summary.idx")], b"new-index")
            self.assertNotIn(PurePosixPath("/") / staging.DESCRIPTOR, ftp.files)
            self.assertNotIn(PurePosixPath("/") / staging.LOCK, ftp.directories)

    def test_activation_rejects_older_versions_and_interrupted_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)
            with patch.object(staging, "verify_https"):
                staging.activate(ftp, public, files, "none", "2.0.0")
                index_path = PurePosixPath("/repo/summary.idx")
                current = hashlib.sha256(ftp.files[index_path]).hexdigest()
                with self.assertRaisesRegex(RuntimeError, "older"):
                    staging.activate(ftp, public, files, current, "1.9.9")
                ftp.files[index_path] = b"incomplete-update"
                changed = hashlib.sha256(b"incomplete-update").hexdigest()
                with self.assertRaisesRegex(RuntimeError, "manual recovery"):
                    staging.activate(ftp, public, files, changed, "2.0.1")
            self.assertEqual(ftp.files[index_path], b"incomplete-update")

    def test_same_release_cannot_replace_index_with_different_content(self):
        with tempfile.TemporaryDirectory() as directory:
            public = self.publication(Path(directory))
            ftp = FakeFtp()
            files = staging.publication_files(public)
            staging.stage(ftp, public, files)
            with patch.object(staging, "verify_https"):
                staging.activate(ftp, public, files, "none", "1.0.0")
                index = PurePosixPath("/repo/summary.idx")
                current = hashlib.sha256(ftp.files[index]).hexdigest()
                (public / "repo/summary.idx").write_bytes(b"different-index")
                with self.assertRaisesRegex(RuntimeError, "changed version"):
                    staging.activate(ftp, public, files, current, "1.0.0")
            self.assertEqual(ftp.files[index], b"new-index")


if __name__ == "__main__":
    unittest.main()
