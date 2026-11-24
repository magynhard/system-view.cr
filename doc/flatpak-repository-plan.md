# Plan: Flatpak updates via `flatpak.magynhard.de`

## Goal

Publish a signed Flatpak repository for System View on our web host. Users
install once from a `.flatpakref` and receive subsequent releases through
`flatpak update` or a software center with Flatpak support. Keep the AppImage
and standalone `.flatpak` downloads and their checksums unchanged.

GitHub Actions builds, signs, and uploads the repository over FTP with TLS
(FTPS). The web host serves static files over HTTPS and does not need Flatpak
installed. Flathub continues to supply `org.gnome.Platform//51`, not System
View. No app code, network permissions, or Flatpak sandbox settings change.

## Implementation

1. **Reuse the existing builds.** In `.github/workflows/linux-packages.yml`,
   preserve the normal bundle artifacts and export the existing OSTree
   repository from each native Flatpak build as a separate, short-lived
   artifact. Reuse the app commits produced by `scripts/build-flatpak.sh`;
   do not rebuild the app in the publishing job. Publish `x86_64` and
   `aarch64` together. Keep the existing Flatpak branch `master` (confirmed
   in the local export) to avoid introducing a different ref for users
   switching from a standalone bundle.
2. **Assemble and sign a single repository.** Add a small publishing script
   under `scripts/` that imports the two app refs from the build artifacts
   into a fresh archive-mode OSTree repository. Validate both refs and their
   commit IDs, sign the app commits, then generate signed AppStream metadata
   and repository summaries. Verify the result using only the public key.
   Stage a snapshot with only the current release; clients can reuse local
   OSTree objects without the server retaining historical commits. Measure
   transfer and site size before deciding whether to add static deltas.
3. **Stage the install link.** Publish the repository at
    `https://flatpak.magynhard.de/system-view/repo/` and the install file
    at `https://flatpak.magynhard.de/system-view/de.magynhard.SystemView.flatpakref`.
   The file declares `Name=de.magynhard.SystemView`, `Branch=master`,
   `IsRuntime=false`, the repository URL, a stable suggested remote name,
   the Flathub runtime source, and the base64-encoded public signing key.
   A separate `.flatpakrepo` is not needed for this single-app install flow.
4. **Publish only from supported releases.** Add a dedicated FTPS deployment
   path to `linux-packages.yml`, dependent on the successful package builds
   and separate from the existing release-asset upload. PRs, master pushes,
   and manual runs may assemble/test with an ephemeral key but must not
   deploy or access the production signing key. Publish only the latest
   stable, version-matched release. Serialize deployments, check release
   eligibility again just before deployment, and record the deployed version
   in the site so a rerun cannot replace it with a lower version. A missing
   architecture or failed signing check must leave the existing site untouched.
    Report FTPS deployment failures independently of release asset status.
5. **Set up the host and signing.** Use explicit FTPS. The FTP login root maps
    to the public webroot; keep the repository, descriptor, and deployment lock
    under `/system-view/`. Other apps can use sibling directories. Use a
    dedicated deployment account. Store `FTPS_HOST`, `FTPS_PORT`, `FTPS_USERNAME`, and
    `FTPS_PASSWORD` as GitHub environment secrets and inject them as environment
    variables only in the upload step. Do not commit the values, provide
    defaults, or print them; fail before connecting if any are missing. The
    public HTTPS URL is separate from the private upload endpoint and can
    appear in the descriptor and docs. Require TLS on both control and data
    connections and verify the server certificate; never fall back to plain
    FTP. Create a dedicated OpenPGP signing key offline,
    keep the primary key and backups offline, and store only the CI signing
    subkey as a protected environment secret for the signing job. Verify its
    expected fingerprint and keep private material out of artifacts and logs.
    Document key renewal/replacement before launching.
    For local testing, document an opt-in invocation with a trusted local
    `.env` file and the same `FTPS_*` variables. Do not auto-load it or add a
    Crystal dependency: the deploy script reads its environment in both
    cases. Exclude `/.env` from Git, the AppImage Docker build context, and
    the Flatpak source snapshot before creating a file with real credentials.
    A tracked `.env.example` may contain empty placeholders only.
6. **Upload data before publishing metadata.** On a test directory, verify
    that the host supports renaming uploaded temporary files over existing
    files and that the result is visible via HTTPS. Upload new OSTree objects
    and other content-addressed files first, then activate refs and signed
    summary metadata using verified per-file renames. Publish the install link
    only once the repository passes the live checks. FTPS does not provide an
    atomic switch for multiple files: test metadata replacement and recovery
    after an interrupted upload, including how caches handle summary changes.
    Keep old objects for in-flight requests and retain the previous metadata
    to recover an interrupted deployment. Do not use a deleting mirror;
    plan quota-aware cleanup separately.
    A local HTTP test now exercises an indexed-only layout: upload objects and
    `summaries/` first, then replace `summary.idx` as the final visibility
    switch. The test passes with Flatpak 1.18.4 and preserves previous objects.
    Confirm support on all targeted Flatpak versions and test the actual
    server's rename and cache behavior before adopting this for production.
7. **Document installation and migration.** Once the live remote is verified,
   link the `.flatpakref` in `README.md` and document the install, origin check,
   and update commands in `doc/packaging.md`. Existing standalone installs
   do not switch origins by themselves. Test and document reinstalling from
   the new source in the same installation scope while keeping app data.
   Keep the direct bundle clearly labeled as a manual-update alternative.

## Verification and rollout

- Extend `make test-packaging` with deterministic checks for descriptor
  contents and missing or mismatched architecture inputs. Run
  `make validate-metadata`, `python3 scripts/packaging.py verify`, and
  `git diff --check`. Build the affected package locally and check both
  architectures in native CI.
- Serve a test repository over local HTTP and use an isolated Flatpak
  installation. Install version A through the `.flatpakref`, check the
  origin, replace the served repository with a separately built and signed
  version B, then confirm `flatpak update` deploys version B without a
  reinstall. Test that an incorrectly signed commit is rejected. Check the
  supported refs and AppStream data for both architectures.
- Before the first live release, test FTPS uploads and file replacement in a
  test directory and verify that the web host serves extensionless OSTree files
  and repository metadata over HTTPS. Then, after explicit approval, bootstrap
  from the next stable release. Verify a clean install from the public
  descriptor, the application launch, and the listing in a Flatpak-enabled
  software center. Confirm the public update path again with the following
  release. Do not advertise the link before the first live install succeeds.
- Check the hosting plan's storage, file-count, and traffic limits before
  launch and monitor repository growth. If a broken build is published,
  ship a newer fixed release rather than expecting clients to downgrade.

## References

- [Flatpak repository hosting](https://docs.flatpak.org/en/latest/hosting-a-repository.html)
- [Flatpak repositories and `.flatpakref`](https://docs.flatpak.org/en/latest/repositories.html)
