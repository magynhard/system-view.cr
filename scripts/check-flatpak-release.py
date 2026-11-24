#!/usr/bin/env python3
"""Fail unless the triggering release is still the latest stable release."""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check(api_url, repository, token, tag, release_id):
    url = urllib.parse.urlsplit(api_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("Invalid GitHub API URL")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Expected a numeric stable release tag")
    if not release_id.isdecimal() or not token:
        raise ValueError("Missing release ID or GitHub token")
    request = urllib.request.Request(
        f"{api_url.rstrip('/')}/repos/{repository}/releases/latest",
        headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
        release = json.load(response)
    if (not isinstance(release, dict) or str(release.get("id")) != release_id or release.get("tag_name") != tag or
            release.get("draft") or release.get("prerelease")):
        raise ValueError("Triggering release is no longer the latest stable release")


def main():
    try:
        check(os.environ["GITHUB_API_URL"], os.environ["GITHUB_REPOSITORY"],
              os.environ["GH_TOKEN"], os.environ["RELEASE_TAG"], os.environ["RELEASE_ID"])
    except (KeyError, ValueError, OSError, urllib.error.URLError):
        print("Could not verify the latest stable release; publication stopped.", file=sys.stderr)
        return 1
    print("Triggering release is the latest stable release.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
