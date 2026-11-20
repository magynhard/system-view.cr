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
flatpak install --user System_View-0.3.3-x86_64.flatpak
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
flatpak install --user dist/System_View-0.3.3-x86_64.flatpak
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
plus display, IPC and DRI access for the GUI. It does not request UDisks2,
unrestricted system-bus access or a shared network namespace. Targeted system-bus
permissions for `org.freedesktop.NetworkManager` and `org.bluez` support the
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
pinned for x86_64/aarch64; the automated workflow currently builds x86_64 only.

## Updating inputs

`packaging/sources.json` records archive hashes and exact shard commits. Keep its
versions and URLs aligned with `shard.lock`, and update the pins whenever
dependencies change. Build images and runtime branches follow the base project's
conventions; they are not fully bit-for-bit reproducible OS snapshots.

```sh
python3 scripts/packaging.py verify
make test-packaging
```

## GitHub releases

`.github/workflows/linux-packages.yml` runs on `master` pushes, pull requests,
manual dispatch and published GitHub releases. Both package jobs upload workflow
artifacts. Only the `release: published` event enables the `release-assets` job,
which waits for both builds and attaches all four distribution files.

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
   Flatpak and a separate SHA-256 file for each. Report failures and missing
   assets accurately; return the release URL only with its actual status.

Version bumps, release notes, commits, tags and publication are explicit actions.
Pushing a tag alone does not publish a GitHub release or attach packages.
