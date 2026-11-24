#!/usr/bin/env python3
"""Upload Flatpak repository data over FTPS without activating a release."""

import argparse
import base64
import configparser
import ftplib
import hashlib
import http.client
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

REQUIRED = ("FTPS_HOST", "FTPS_PORT", "FTPS_USERNAME", "FTPS_PASSWORD")
SAFE_NAME = re.compile(r"^[A-Za-z0-9._+-]+$")
LOCK = "system-view-staging.lock"
PUBLIC_HOST = "flatpak.magynhard.de"
APP_ROOT = "/system-view"
DESCRIPTOR = "de.magynhard.SystemView.flatpakref"
RELEASE_RECORD = "system-view-release.json"
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def settings(environment):
    missing = [name for name in REQUIRED if not environment.get(name)]
    if missing:
        raise ValueError("Missing environment variables: " + ", ".join(missing))
    try:
        port = int(environment["FTPS_PORT"])
    except ValueError:
        raise ValueError("FTPS_PORT must be a valid port number") from None
    if not 1 <= port <= 65535:
        raise ValueError("FTPS_PORT must be a valid port number")
    return environment["FTPS_HOST"], port, environment["FTPS_USERNAME"], environment["FTPS_PASSWORD"]


def publication_files(publication):
    repo = publication / "repo"
    if repo.is_symlink() or not repo.is_dir():
        raise ValueError("Missing or unsafe repository")
    index = repo / "summary.idx"
    descriptor = publication / DESCRIPTOR
    if (index.is_symlink() or not index.is_file() or
            descriptor.is_symlink() or not descriptor.is_file()):
        raise ValueError("Missing or unsafe publication metadata")
    files = []
    for name in ("config", "objects", "summaries"):
        source = repo / name
        if source.is_symlink() or not source.exists():
            raise ValueError(f"Missing or unsafe repository entry: {name}")
        if name == "config":
            if not source.is_file():
                raise ValueError("Repository config must be a file")
            files.append(source)
            continue
        if not source.is_dir():
            raise ValueError(f"Repository entry must be a directory: {name}")
        for path in source.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError("Repository contains an unsafe file")
            if path.is_file():
                files.append(path)
    for path in files:
        if not all(SAFE_NAME.fullmatch(part) and part not in (".", "..")
                   for part in path.relative_to(repo).parts):
            raise ValueError("Repository contains an unsafe filename")
    if not any(path.is_relative_to(repo / "objects") for path in files):
        raise ValueError("Repository has no objects")
    if not any(path.is_relative_to(repo / "summaries") for path in files):
        raise ValueError("Repository has no indexed summaries")
    return sorted(files)


def verify_publication(publication):
    manifest = publication / "publication.json"
    signature = publication / "publication.json.sig"
    descriptor = publication / DESCRIPTOR
    if any(path.is_symlink() or not path.is_file() for path in (manifest, signature, descriptor)):
        raise ValueError("Missing or unsafe signed publication metadata")
    try:
        parsed = configparser.ConfigParser(interpolation=None)
        parsed.read(descriptor)
        info = parsed["Flatpak Ref"]
        if (info["Name"] != "de.magynhard.SystemView" or info["Branch"] != "master" or
                info["Url"] != f"https://{PUBLIC_HOST}{APP_ROOT}/repo/"):
            raise ValueError("Flatpak descriptor does not match the expected application")
        key = base64.b64decode(info["GPGKey"], validate=True)
        record = json.loads(manifest.read_bytes())
        if (record["application"] != "de.magynhard.SystemView" or
                not isinstance(record["version"], str) or not VERSION.fullmatch(record["version"]) or
                record["index_sha256"] != local_digest(publication / "repo/summary.idx").hex() or
                record["descriptor_sha256"] != local_digest(descriptor).hex()):
            raise ValueError("Signed publication metadata does not match the prepared files")
    except (KeyError, TypeError, ValueError, configparser.Error):
        raise ValueError("Invalid or mismatched signed publication metadata") from None
    with tempfile.TemporaryDirectory() as directory:
        keyring = Path(directory) / "trusted.gpg"
        keyring.write_bytes(key)
        verified = subprocess.run(["gpgv", "--homedir", directory, "--keyring", str(keyring),
                                   str(signature), str(manifest)], capture_output=True)
        if verified.returncode:
            raise ValueError("Publication metadata signature verification failed")
    return record["version"]


def entries(ftp):
    return dict(ftp.mlsd())


def enter_directory(ftp, parts):
    ftp.cwd(APP_ROOT)
    for part in parts:
        listing = entries(ftp)
        if part not in listing:
            ftp.mkd(part)
        elif listing[part].get("type") != "dir":
            raise RuntimeError("Remote repository path is not a directory")
        ftp.cwd(part)


def remote_digest(ftp, name):
    digest = hashlib.sha256()
    ftp.retrbinary("RETR " + name, digest.update)
    return digest.digest()


def local_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").digest()


def stage(ftp, publication, files):
    """Stage only immutable data; never upload the index or descriptor."""
    ftp.cwd("/")
    app_directory = APP_ROOT.lstrip("/")
    listing = entries(ftp)
    if app_directory not in listing:
        try:
            ftp.mkd(app_directory)
        except ftplib.error_perm:
            if entries(ftp).get(app_directory, {}).get("type") != "dir":
                raise
    elif listing[app_directory].get("type") != "dir":
        raise RuntimeError("Remote application path is not a directory")
    ftp.cwd(APP_ROOT)
    ftp.mkd(LOCK)
    locked = True
    temporary = None
    try:
        for path in files:
            relative = path.relative_to(publication / "repo")
            enter_directory(ftp, ("repo", *relative.parts[:-1]))
            name = relative.name
            digest = local_digest(path)
            listing = entries(ftp)
            if name in listing:
                if listing[name].get("type") != "file" or remote_digest(ftp, name) != digest:
                    raise RuntimeError("Existing remote repository data differs")
                continue
            temporary = "system-view-upload-" + secrets.token_hex(16) + ".tmp"
            with path.open("rb") as stream:
                ftp.storbinary("STOR " + temporary, stream)
            if remote_digest(ftp, temporary) != digest:
                raise RuntimeError("Uploaded file verification failed")
            if name in entries(ftp):
                raise RuntimeError("Remote repository changed during staging")
            ftp.rename(temporary, name)
            temporary = None
    finally:
        active_error = sys.exc_info()[0] is not None
        cleanup_failed = False
        if temporary is not None:
            try:
                ftp.delete(temporary)
            except (ftplib.Error, OSError, EOFError):
                print(f"Could not remove temporary upload {temporary}.", file=sys.stderr)
                cleanup_failed = True
        if locked:
            try:
                ftp.cwd(APP_ROOT)
                ftp.rmd(LOCK)
            except (ftplib.Error, OSError, EOFError):
                print(f"Could not remove {LOCK}; inspect it before retrying.", file=sys.stderr)
                cleanup_failed = True
        if cleanup_failed and not active_error:
            raise RuntimeError("Staging cleanup failed")


def verify_https(path, expected_digest, expected_size):
    connection = http.client.HTTPSConnection(PUBLIC_HOST, timeout=30, context=ssl.create_default_context())
    try:
        connection.request("GET", APP_ROOT + path, headers={"Cache-Control": "no-cache"})
        response = connection.getresponse()
        digest = hashlib.sha256()
        remaining = expected_size + 1
        while remaining and (chunk := response.read(min(1024 * 1024, remaining))):
            digest.update(chunk)
            remaining -= len(chunk)
        if response.status != 200 or remaining != 1 or digest.digest() != expected_digest:
            raise RuntimeError("Public HTTPS content does not match the staged data")
    finally:
        connection.close()


def atomic_upload(ftp, source, name):
    temporary = "system-view-upload-" + secrets.token_hex(16) + ".tmp"
    try:
        with source.open("rb") as stream:
            ftp.storbinary("STOR " + temporary, stream)
        if remote_digest(ftp, temporary) != local_digest(source):
            raise RuntimeError("Uploaded metadata verification failed")
        ftp.rename(temporary, name)
        temporary = None
    finally:
        if temporary is not None:
            try:
                ftp.delete(temporary)
            except (ftplib.Error, OSError, EOFError):
                print(f"Could not remove temporary upload {temporary}.", file=sys.stderr)


def read_release_record(ftp):
    data = bytearray()

    def receive(chunk):
        data.extend(chunk)
        if len(data) > 4096:
            raise RuntimeError("Remote release record is too large")

    ftp.retrbinary("RETR " + RELEASE_RECORD, receive)
    try:
        record = json.loads(data)
        version = record["version"]
        index = record["index_sha256"]
        if (not isinstance(version, str) or not VERSION.fullmatch(version) or
                not isinstance(index, str) or not re.fullmatch(r"[a-f0-9]{64}", index)):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("Invalid remote release record") from None
    return version, index


def activate(ftp, publication, files, expected, version):
    """Manually publish an already staged snapshot after HTTPS verification."""
    if not VERSION.fullmatch(version):
        raise ValueError("Release version must be a numeric MAJOR.MINOR.PATCH")
    ftp.cwd(APP_ROOT)
    ftp.mkd(LOCK)
    try:
        for path in files:
            relative = path.relative_to(publication / "repo")
            verify_https("/repo/" + relative.as_posix(), local_digest(path), path.stat().st_size)

        ftp.cwd(APP_ROOT)
        root_entries = entries(ftp)
        descriptor = publication / DESCRIPTOR
        descriptor_exists = DESCRIPTOR in root_entries
        if descriptor_exists and (root_entries[DESCRIPTOR].get("type") != "file" or
                                  remote_digest(ftp, DESCRIPTOR) != local_digest(descriptor)):
            raise RuntimeError("Existing Flatpak descriptor differs")

        ftp.cwd("repo")
        repo_entries = entries(ftp)
        if "summary.idx" in repo_entries:
            if repo_entries["summary.idx"].get("type") != "file":
                raise RuntimeError("Existing index is not a file")
            current = remote_digest(ftp, "summary.idx").hex()
        else:
            current = "none"
        if current != expected:
            raise RuntimeError("Current index does not match the expected index")

        index = publication / "repo/summary.idx"
        new_index = local_digest(index).hex()
        if RELEASE_RECORD in repo_entries:
            if repo_entries[RELEASE_RECORD].get("type") != "file":
                raise RuntimeError("Existing release record is not a file")
            old_version, old_index = read_release_record(ftp)
            if old_index != current:
                raise RuntimeError("Release record and active index differ; manual recovery required")
            old_parts = tuple(map(int, old_version.split(".")))
            new_parts = tuple(map(int, version.split(".")))
            if new_parts < old_parts or (new_parts == old_parts and new_index != current):
                raise RuntimeError("Refusing to replace the current release with an older or changed version")
        elif current != "none":
            raise RuntimeError("Existing index has no release record; manual recovery required")

        record = json.dumps({"version": version, "index_sha256": new_index}, sort_keys=True) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            record_file = Path(directory) / RELEASE_RECORD
            record_file.write_text(record, encoding="utf-8")
            atomic_upload(ftp, record_file, RELEASE_RECORD)
        atomic_upload(ftp, index, "summary.idx")
        verify_https("/repo/summary.idx", local_digest(index), index.stat().st_size)
        if not descriptor_exists:
            ftp.cwd(APP_ROOT)
            atomic_upload(ftp, descriptor, DESCRIPTOR)
        verify_https("/" + DESCRIPTOR, local_digest(descriptor), descriptor.stat().st_size)
    finally:
        active_error = sys.exc_info()[0] is not None
        try:
            ftp.cwd(APP_ROOT)
            ftp.rmd(LOCK)
        except (ftplib.Error, OSError, EOFError):
            print(f"Could not remove {LOCK}; inspect it before retrying.", file=sys.stderr)
            if not active_error:
                raise RuntimeError("Activation lock cleanup failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publication", type=Path, help="output of prepare-flatpak-publication.py")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--confirm-stage", action="store_true", help="authorize inactive uploads to the FTPS server")
    actions.add_argument("--confirm-activate", action="store_true", help="authorize publishing the staged index")
    parser.add_argument("--expected-current-index", help="'none' or SHA-256 of the current remote index")
    parser.add_argument("--release-version", help="numeric MAJOR.MINOR.PATCH of the staged release")
    args = parser.parse_args()
    if args.confirm_activate and not re.fullmatch(r"none|[a-f0-9]{64}", args.expected_current_index or ""):
        parser.error("--confirm-activate requires --expected-current-index=none or a lowercase SHA-256")
    if args.confirm_stage and args.expected_current_index is not None:
        parser.error("--expected-current-index is only valid with --confirm-activate")
    if args.confirm_activate and not VERSION.fullmatch(args.release_version or ""):
        parser.error("--confirm-activate requires --release-version=MAJOR.MINOR.PATCH")
    if args.confirm_stage and args.release_version is not None:
        parser.error("--release-version is only valid with --confirm-activate")
    try:
        config = settings(os.environ)
        files = publication_files(args.publication)
        version = verify_publication(args.publication)
        if args.confirm_activate and args.release_version != version:
            raise ValueError("Release version does not match signed publication metadata")
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print("Unable to verify local publication metadata.", file=sys.stderr)
        return 1

    ftp = ftplib.FTP_TLS(context=ssl.create_default_context(), timeout=30)
    try:
        ftp.connect(config[0], config[1])
        ftp.login(config[2], config[3])
        ftp.prot_p()
        if args.confirm_stage:
            stage(ftp, args.publication, files)
        else:
            activate(ftp, args.publication, files, args.expected_current_index, args.release_version)
    except (ftplib.Error, OSError, EOFError, RuntimeError) as error:
        message = ("no index was activated" if args.confirm_stage else
                   "the index may already be active; inspect the public repository before retrying")
        print(f"FTPS operation failed ({type(error).__name__}); {message}.", file=sys.stderr)
        return 1
    finally:
        ftp.close()
    if args.confirm_stage:
        print("Repository data staged; no index or Flatpak descriptor was published.")
    else:
        print("The Flatpak repository index and descriptor are active.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
