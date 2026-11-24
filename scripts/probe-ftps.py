#!/usr/bin/env python3
"""Test an explicitly authorized, temporary FTPS upload and HTTPS retrieval."""

import argparse
import ftplib
import http.client
import io
import os
import secrets
import ssl
import sys

PUBLIC_HOST = "flatpak.magynhard.de"
REQUIRED = ("FTPS_HOST", "FTPS_PORT", "FTPS_USERNAME", "FTPS_PASSWORD")


def configuration(environment):
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


def fetch_https(path, expected):
    connection = http.client.HTTPSConnection(PUBLIC_HOST, timeout=20, context=ssl.create_default_context())
    try:
        connection.request("GET", path, headers={"Cache-Control": "no-cache"})
        response = connection.getresponse()
        content = response.read(len(expected) + 1)
        if response.status != 200 or content != expected:
            raise RuntimeError("HTTPS returned an unexpected response or file content")
    finally:
        connection.close()


def probe(settings):
    host, port, username, password = settings
    directory = "system-view-ftps-test-" + secrets.token_hex(16)
    first = secrets.token_bytes(32)
    second = secrets.token_bytes(32)
    created = False
    inside = False
    cleanup_failed = False
    ftp = ftplib.FTP_TLS(context=ssl.create_default_context(), timeout=20)
    try:
        ftp.connect(host, port)
        ftp.login(username, password)
        ftp.prot_p()
        ftp.mkd(directory)
        created = True
        ftp.cwd(directory)
        inside = True
        ftp.storbinary("STOR test", io.BytesIO(first))
        fetch_https(f"/{directory}/test?version=1", first)
        ftp.storbinary("STOR test.next", io.BytesIO(second))
        ftp.rename("test.next", "test")
        fetch_https(f"/{directory}/test?version=2", second)
    finally:
        if inside:
            for name in ("test.next", "test"):
                try:
                    ftp.delete(name)
                except ftplib.error_perm as error:
                    # A successfully renamed file no longer has the temporary name.
                    if not str(error).startswith("550"):
                        cleanup_failed = True
                except (OSError, EOFError, ftplib.Error):
                    cleanup_failed = True
            try:
                ftp.cwd("..")
            except (OSError, EOFError, ftplib.Error):
                cleanup_failed = True
                inside = False
            else:
                inside = False
                try:
                    ftp.rmd(directory)
                    created = False
                except (OSError, EOFError, ftplib.Error):
                    cleanup_failed = True
        try:
            ftp.close()
        except OSError:
            cleanup_failed = True
        if created or cleanup_failed:
            print(f"Cleanup incomplete; inspect the test directory {directory}.", file=sys.stderr)
            if sys.exc_info()[0] is None:
                raise RuntimeError("Test directory cleanup failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-test-upload", action="store_true",
                        help="allow creation and deletion of a unique test directory in the FTP root")
    args = parser.parse_args()
    if not args.confirm_test_upload:
        parser.error("pass --confirm-test-upload to authorize temporary files on the server")
    try:
        settings = configuration(os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    try:
        probe(settings)
    except (ftplib.Error, OSError, EOFError, RuntimeError) as error:
        print(f"FTPS/HTTPS probe failed ({type(error).__name__}); check the host and TLS configuration.",
              file=sys.stderr)
        return 1
    print("FTPS upload, replacement, and HTTPS retrieval succeeded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
