# Packaging

System View follows Disk View's two independent Linux package builds. The source
version is `shard.yml`; the newest AppStream release must match it.

## AppImage

Requires Docker and an x86_64 host:

```sh
make appimage
```

The Ubuntu 24.04 builder downloads SHA-256-pinned compiler/tool archives and
commit-pinned shards, then generates bindings, checks formatting, runs specs,
installs the application and bundles GTK/libadwaita with linuxdeploy. It embeds
the application icon, a PCI names database and the libdrm AMD model database.
The runtime hook preserves
automatic theme and Wayland/X11 selection. Minimum host glibc is 2.39.

Outputs:

- `dist/System_View-VERSION-x86_64.AppImage`
- `dist/System_View-VERSION-x86_64.AppImage.sha256`

Run with `chmod +x System_View-*.AppImage` followed by the executable. On systems
without FUSE use `APPIMAGE_EXTRACT_AND_RUN=1 ./System_View-VERSION-x86_64.AppImage`.

## Standalone Flatpak

To install a downloaded release bundle for your user, run:

```sh
flatpak install --user System_View-0.4.0-x86_64.flatpak
flatpak run de.magynhard.SystemView
```

Alternatively, launch System View from the applications menu. Flatpak exports a
desktop launcher; it does not install `system-view` into `~/.local/bin`. The
GNOME 51 runtime is a separate dependency and can be installed from Flathub.
Single-file bundles do not include repository AppStream data, so software
managers may not show a screenshot when installing directly from a bundle.

### Building the Flatpak

Requires Flatpak 1.17+, flatpak-builder, OSTree, AppStream with compose support,
Python 3.12+, PyYAML and the GNOME 51 SDK/runtime:

```sh
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.gnome.Platform//51 org.gnome.Sdk//51
make flatpak
flatpak install --user dist/System_View-0.4.0-x86_64.flatpak
flatpak run de.magynhard.SystemView
```

The generated local manifest is `build/flatpak/de.magynhard.SystemView.json`.
Sources are snapshotted without generated files or Git data. Dependency downloads
are pinned; compilation is offline. GNOME's runtime supplies GTK/libadwaita.
Flatpak bundles and their `.sha256` files are written under `dist/`.
The package includes `glxinfo` and `vulkaninfo`; X11 access is provided even in
Wayland sessions so `glxinfo` can query XWayland. Graphics information remains
unavailable when the display, driver or GPU attribution cannot be determined.

To verify the packaged app graphically, install the bundle and run it through
`flatpak run` as shown above. Do not rely on `flatpak-builder --run` for window
checks: it strips `DISPLAY` from the environment and does not expose the X11
socket, so GTK silently falls back to the host Wayland display instead of a
test Xvfb screen, and screenshots of the test display stay black while the app
is healthy.

The sandbox uses read-only `host-root` access for host hardware/OS identification
and read-only `/run/udev` access for cached installed-RAM/module information,
plus display, IPC and DRI access for the GUI. It does not request unrestricted
system-bus access or a shared network namespace. Targeted system-bus permissions
for `org.freedesktop.UDisks2` allow reading cached drive health properties without
opening devices or triggering an update. Permissions for
`org.freedesktop.NetworkManager` and `org.bluez` support the
Network page's read-only property/settings queries; no discovery or configuration
methods are called. The `org.gnome.Shell` session-bus permission is used to read
the active desktop version; `org.gnome.Mutter.DisplayConfig` supplies current
monitor modes and primary status through `GetCurrentState` only. Host OS information is mapped from `/run/host`; sysfs/procfs
fall back to their sandbox-visible read-only views when necessary. Information
hidden by the host or sandbox remains Unknown. Check the hardware inventory on
the intended host after installation.

The optional pkexec/dmidecode action requires the host tools and a desktop
authorization agent. The Flatpak uses `flatpak-spawn --host` to run the same
fixed read-only query on the host after authorization. The permission to access
`org.freedesktop.Flatpak` permits host command execution outside the sandbox and
therefore makes the sandbox unsuitable as a security boundary for this app.

This is a local/standalone packaging manifest, **not a Flathub submission**. No
Flathub submission or publication is configured. Compiler architectures are
pinned for x86_64/aarch64; the automated workflow builds Flatpak bundles for
both architectures on native GitHub-hosted runners.

## Updating inputs

`packaging/sources.json` records archive hashes and exact shard commits. Keep its
versions and URLs aligned with `shard.lock`, and update the pins whenever
dependencies change. Build images and runtime branches follow the base project's
conventions; they are not fully bit-for-bit reproducible OS snapshots.

```sh
python3 scripts/packaging.py verify
make test-packaging
```

## Local deployment credentials

The planned Flatpak repository deployment will use `FTPS_HOST`, `FTPS_PORT`,
`FTPS_USERNAME`, and `FTPS_PASSWORD`. For local testing, copy `.env.example`
to `.env` and fill in the values. The file is ignored by Git and excluded from
the Flatpak source snapshot and the AppImage Docker build context.

To test the FTP account and webroot without publishing the app, load a trusted
file explicitly in a subshell and authorize a temporary upload:

```sh
(
  set -a
  source .env
  set +a
  python3 scripts/probe-ftps.py --confirm-test-upload
)
```

The file is shell code: quote values as shell strings and never source an
untrusted file. The probe requires explicit FTP over TLS with validated
certificates on the control and data connections. It creates a uniquely named
directory in the FTP root, checks the file via HTTPS, replaces it using FTP
rename, checks the replacement via HTTPS, and removes its test files. If
cleanup fails, it prints the test directory name for manual removal. It does
not touch the repository or publish anything. The actual deployment workflow
will receive the same variables from GitHub environment secrets instead.

## Local Flatpak repository test

`make test-packaging` tests signed repository assembly and, when Flatpak,
OSTree and GPG are installed, uses an isolated user installation and a local
HTTP server to install and update a small fixture app. It also checks that an
update signed with a different key is rejected. It does not publish anything,
test FTPS, or replace the separately required real-application package tests.
After `make flatpak` on x86_64, exercise the actual finalized app and its
AppStream metadata over local HTTP as well:

```sh
SYSTEM_VIEW_TEST_FLATPAK_BUILD=build/flatpak/app \
  python3 -m unittest discover -s tests -p test_flatpak_repository.py -v
```

This creates two test commits of the same built application, not two application
releases, and uses a temporary aarch64 fixture. The x86_64 CI build runs this
check too.

To assemble two existing architecture-specific OSTree build repositories:

```sh
bash scripts/assemble-flatpak-repo.sh X86_REPO ARM_REPO NEW_OUTPUT_DIR GPG_HOME FULL_KEY_FINGERPRINT
```

The output directory must not exist. The script imports the `master` app ref
for each architecture, signs the commits and repository metadata, verifies
the commits with the exported public key, and generates a `.flatpakref` for
`https://flatpak.magynhard.de/system-view/repo/`. The result is local only. Use a temporary
test key for experiments; do not publish a descriptor containing a test key.

Prepare the files for static hosting with:

```sh
python3 scripts/prepare-flatpak-publication.py \
  ASSEMBLED_DIR NEW_PUBLIC_DIR GPG_HOME FULL_KEY_FINGERPRINT
```

Preparation verifies the signed AppStream metadata for both architectures,
requires matching numeric release versions, and signs a local publication
manifest binding that version to the index and descriptor. The FTPS command
verifies this signature and checks the supplied release version before it
connects. These manifest files are not uploaded.

This prepares an indexed repository with `summary.idx` and the content it
references, but omits the legacy `summary` and `summary.sig` pair. The local
HTTP integration test stages the next version's objects before atomically
replacing the index and verifies that an installed client sees the old version
until the replacement. It has been exercised with Flatpak 1.18.4; compatibility
with every supported Flatpak version and the real web host still needs testing.
This command does not connect to or upload files to a server.

After the FTPS probe succeeds and the signing key and publication are ready,
the data-only staging command can be run explicitly:

```sh
(
  set -a
  source .env
  set +a
  python3 scripts/stage-flatpak-ftps.py NEW_PUBLIC_DIR --confirm-stage
)
```

It uses explicit FTPS with certificate validation and encrypted data
connections. The FTPS login root maps to the webroot. System View uses its own
`/system-view/` directory, with the `.flatpakref` alongside `repo/`, so other
apps can use sibling directories. Staging uploads `config`, `objects/`, and
`summaries/` to `/system-view/repo/` only, verifying
each uploaded file and comparing existing files rather than overwriting them.
It uses a temporary server-side lock; after an interrupted run, inspect a
remaining `/system-view/system-view-staging.lock` directory before removing it manually.
Staging does **not** publish `summary.idx` or the `.flatpakref` and cannot
activate an update. It requires FTP `MLSD` support; this has not yet been
verified with the hosting provider.

Manual activation is a separate, explicitly authorized operation. Before using
it, run the FTPS probe successfully, verify the signed input and signing-key
fingerprint independently, and check that the host replaces files atomically.
The following is only for a first publication when no index exists:

```sh
(
  set -a
  source .env
  set +a
  python3 scripts/stage-flatpak-ftps.py NEW_PUBLIC_DIR \
    --confirm-activate --expected-current-index=none --release-version=1.2.3
)
```

For an existing repository, `--expected-current-index` must instead be the
lowercase SHA-256 of the current `/system-view/repo/summary.idx`, obtained independently.
The activation compares this expected value under the staging lock and refuses
to change an existing `.flatpakref` with different content. It verifies the
staged files over HTTPS before replacing the index, then verifies the published
index and descriptor. A server-side release record links the numeric version to
the current index hash and rejects an older version or different content for
the same version. Verify the version against the intended GitHub release before
activation.

The script verifies that the manually supplied version matches the signed
publication manifest. Verify the signing key fingerprint independently before
the first publication; the initial descriptor itself establishes trust for
future installations.

The release record is written before the index. An interruption between the
two leaves them inconsistent, and later activation attempts stop for manual
recovery. A failure after the index rename may leave the new index active;
inspect the public repository before retrying.

### Optional GitHub release publication

The `flatpak-publish` job is **disabled by default**. It runs only for a
published, non-prerelease GitHub release when the repository variable
`FLATPAK_PUBLISH_ENABLED` is set to `true`. Configure and test all of the
following before enabling it:

1. Verify the HTTPS certificate, FTPS probe, server `MLSD` support and atomic
   replacement behavior. Check the live installation path and hosting quota.
2. Create a protected `flatpak-production` GitHub environment and configure
   appropriate deployment approval and branch restrictions. Add environment
   secrets `FTPS_HOST`, `FTPS_PORT`, `FTPS_USERNAME`, `FTPS_PASSWORD`, and
   `FLATPAK_SIGNING_KEY`. Add the full uppercase public primary-key fingerprint
   as the environment variable `FLATPAK_SIGNING_FINGERPRINT`. No FTPS endpoint
   or credentials belong in the repository.
3. Keep the primary OpenPGP key and backups offline. The workflow imports only
   a dedicated signing subkey. Its current non-interactive implementation
   requires the exported subkey to be usable without an interactive passphrase:
   GitHub encrypts the environment secret at rest, but the key is available
   unencrypted to the signing runner during that job. Use a dedicated key,
   restrict environment access, and document revocation and rotation before
   deciding whether this security tradeoff is acceptable.
4. Only after the prerequisites and the first-release procedure are approved,
   set the **repository** variable `FLATPAK_PUBLISH_ENABLED` to `true`.

The job waits for both native builds, the repository test and release assets.
It checks that the triggering release is still GitHub's latest stable release,
signs with the protected subkey, verifies both architecture versions match the
release tag, stages files, and checks the latest release again before
activation. It serializes publication and uses the server-side version and
index checks above. Its OSTree input artifacts expire after seven days; approval
or reruns after that period require a new build. The workflow and live
deployment have not yet been tested on GitHub or the hosting provider.

## GitHub releases

`.github/workflows/linux-packages.yml` runs on `master` pushes, pull requests,
manual dispatch and published GitHub releases. Both package jobs upload workflow
artifacts. The Flatpak job builds both x86_64 and aarch64 bundles and separately
uploads their local OSTree repositories as one-day CI artifacts. A separate
read-only job assembles both repositories with a temporary test key and checks
their AppStream refs; it does not publish or use deployment secrets. Only the
`release: published` event enables the `release-assets` job, which waits for all
builds and attaches the AppImage and both Flatpaks with their SHA-256 files.
The OSTree artifacts are not attached to releases.

1. Inspect the working tree, remote, release history and CI. Choose an unused
   numeric version without a `v` prefix.
2. Update `shard.yml`, `CHANGELOG.md` and the AppStream releases in every supported
   language. Preserve historical entries.
3. Run all checks listed in `AGENTS.md`, including UI tests when relevant. Build
   affected packages locally if their inputs or scripts change.
4. Commit and push to `master`. Wait for `Linux packages` on that exact commit
   to pass; do not tag an untested commit.
5. Tag the tested commit and publish the release, for example:

   ```sh
   git tag -a 0.1.0 TESTED_COMMIT -m "System View 0.1.0"
   git push origin 0.1.0
   gh release create 0.1.0 --verify-tag --title "System View 0.1.0" --notes-file RELEASE_NOTES_FILE --latest
   ```

6. Find the **release-triggered** run and wait for completion:

   ```sh
   gh run list --workflow linux-packages.yml --event release
   gh run watch RUN_ID --exit-status
   gh release view 0.1.0 --json url,assets
   ```

7. Verify the release is published and contains the versioned x86_64 AppImage,
   x86_64 and aarch64 Flatpaks, and a separate SHA-256 file for each. Report
   failures and missing assets accurately; return the release URL only with its
   actual status.

Version bumps, release notes, commits, tags and publication are explicit actions.
Pushing a tag alone does not publish a GitHub release or attach packages.
