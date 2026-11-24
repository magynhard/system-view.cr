#!/usr/bin/env python3
"""Print the current public Flatpak index SHA-256, or none on HTTP 404."""

import hashlib
import http.client
import ssl
import sys


def current_index():
    connection = http.client.HTTPSConnection("flatpak.magynhard.de", timeout=30,
                                             context=ssl.create_default_context())
    try:
        connection.request("GET", "/system-view/repo/summary.idx", headers={"Cache-Control": "no-cache"})
        response = connection.getresponse()
        if response.status == 404:
            return "none"
        if response.status != 200:
            raise ValueError("Unexpected HTTP response")
        digest = hashlib.sha256()
        remaining = 5 * 1024 * 1024 + 1
        while remaining and (chunk := response.read(min(1024 * 1024, remaining))):
            digest.update(chunk)
            remaining -= len(chunk)
        if remaining == 0:
            raise ValueError("Index is too large")
        return digest.hexdigest()
    finally:
        connection.close()


def main():
    try:
        print(current_index())
    except (OSError, http.client.HTTPException, ValueError):
        print("Could not verify the public Flatpak index.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
