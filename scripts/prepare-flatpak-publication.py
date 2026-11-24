#!/usr/bin/env python3
"""Prepare an indexed Flatpak repository for a future static HTTPS upload."""

import argparse
import base64
import configparser
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

APP_ID = "de.magynhard.SystemView"


def prepare(source, destination, gpg_home, fingerprint):
    repo = source / "repo"
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", fingerprint):
        raise ValueError("Expected a full OpenPGP fingerprint")
    files = ("config", "summary.idx")
    directories = ("objects", "summaries")
    for name in files:
        if not (repo / name).is_file() or (repo / name).is_symlink():
            raise ValueError(f"Missing or unsafe repository file: {name}")
    for name in directories:
        path = repo / name
        if not path.is_dir() or path.is_symlink() or any(item.is_symlink() for item in path.rglob("*")):
            raise ValueError(f"Missing or unsafe repository directory: {name}")
    descriptor = source / f"{APP_ID}.flatpakref"
    if not descriptor.is_file() or descriptor.is_symlink():
        raise ValueError("Missing or unsafe Flatpak descriptor")
    key = source / "public-key.gpg"
    if not key.is_file() or key.is_symlink():
        raise ValueError("Missing or unsafe public key")
    exported = subprocess.run(["gpg", "--batch", "--homedir", str(gpg_home), "--export", fingerprint],
                              check=True, capture_output=True).stdout
    if not exported or exported != key.read_bytes():
        raise ValueError("Signing key does not match the repository public key")
    parsed = configparser.ConfigParser(interpolation=None)
    parsed.read(descriptor)
    try:
        embedded = base64.b64decode(parsed["Flatpak Ref"]["GPGKey"], validate=True)
    except (KeyError, ValueError):
        raise ValueError("Invalid Flatpak descriptor public key") from None
    if embedded != exported:
        raise ValueError("Flatpak descriptor public key does not match the signing key")

    with tempfile.TemporaryDirectory() as directory:
        verifier = Path(directory) / "repo"
        def run(*args):
            return subprocess.run(args, check=True, capture_output=True).stdout
        run("ostree", f"--repo={verifier}", "init", "--mode=archive")
        run("ostree", f"--repo={verifier}", "remote", "add", f"--gpg-import={key.resolve()}",
            "verified", repo.resolve().as_uri())
        versions = []
        for arch in ("x86_64", "aarch64"):
            ref = f"appstream2/{arch}"
            run("ostree", f"--repo={verifier}", "pull-local", "--untrusted", "--gpg-verify",
                "--remote=verified", str(repo.resolve()), ref)
            xml = run("ostree", f"--repo={verifier}", "cat", f"verified:{ref}", "/appstream.xml")
            root = ET.fromstring(xml)
            matches = [item for item in root.findall("component") if item.findtext("id") == APP_ID]
            release = matches[0].find("releases/release") if len(matches) == 1 else None
            version = release.get("version", "") if release is not None else ""
            if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
                raise ValueError(f"Missing or invalid release version for {arch}")
            versions.append(version)
        if versions[0] != versions[1]:
            raise ValueError("Architecture release versions do not match")
    if destination.exists():
        raise ValueError("Destination must not already exist")
    destination.mkdir(parents=True)
    target = destination / "repo"
    target.mkdir()
    for name in files:
        shutil.copyfile(repo / name, target / name)
    for name in directories:
        shutil.copytree(repo / name, target / name)
    shutil.copyfile(descriptor, destination / descriptor.name)
    manifest = destination / "publication.json"
    manifest.write_text(json.dumps({
        "application": APP_ID,
        "version": versions[0],
        "index_sha256": hashlib.sha256((target / "summary.idx").read_bytes()).hexdigest(),
        "descriptor_sha256": hashlib.sha256((destination / descriptor.name).read_bytes()).hexdigest(),
    }, sort_keys=True) + "\n", encoding="utf-8")
    subprocess.run(["gpg", "--batch", "--yes", "--homedir", str(gpg_home), "--local-user", fingerprint,
                    "--detach-sign", "--output", str(destination / "publication.json.sig"), str(manifest)],
                   check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="output of assemble-flatpak-repo.sh")
    parser.add_argument("destination", type=Path, help="new directory for the public files")
    parser.add_argument("gpg_home", type=Path, help="signing key home")
    parser.add_argument("fingerprint", help="full signing key fingerprint")
    args = parser.parse_args()
    try:
        prepare(args.source, args.destination, args.gpg_home, args.fingerprint)
    except (ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
