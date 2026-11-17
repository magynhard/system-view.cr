# System View

Crystal + GTK4/libadwaita hardware overview for Linux, initially based on Disk
View's project structure. Use English for code, documentation, release notes and
commit messages. Use conventional commits. Default branch: `master`.
Application ID: `de.magynhard.SystemView`.

## Development

- `src/inventory.cr`: immutable inventory records and read-only Linux discovery.
  Keep it independent of GTK and testable with an injected `LinuxFiles` reader.
  Installed RAM comes from complete cached udev module sizes, never rounded
  MemTotal or maximum array capacity. Deduplicate shared CPU caches across SMT.
- `src/app.cr`: production application activation and window construction. Use
  `activate_signal.connect`, exercise this class directly in UI smoke tests.
- `src/window.cr`: native Adwaita UI, adaptive sidebar and background discovery.
- `src/peripherals.cr`: monitor EDID, ALSA audio and input-device metadata.
- `src/display_config.cr`: bounded read-only GNOME display state, numbering and
  primary/current-mode matching; keep preferred EDID timings separate.
- `src/graphics_diagnostics.cr`: bounded optional unprivileged graphics queries;
  verify PCI attribution, never confuse loader and physical-device API versions.
- `src/subprocess_output.cr`: GIO child-process I/O for background workers. Do not
  use Crystal `Process.run`/IO::Memory pipes while GTK occupies the main thread;
  their copy fibers depend on the blocked default Crystal scheduler.
- `src/firmware.cr`: fixed authorized dmidecode query and CPU/RAM result parser.
- `src/ram_identity.cr`, `data/ram-identifiers.json`: embedded RAM prefix mapping;
  retain only manufacturer and series, without inferring module generation/type.
- `src/desktop.cr`: active desktop identity and bounded GNOME Shell version query.
- `src/network.cr`: physical LAN/Wi-Fi links, bounded read-only NetworkManager
  and BlueZ queries; keep IP/DNS/DHCP scoped to each interface. Never scan, connect
  or modify settings. Do not infer Bluetooth bitrate from a version number.
- `src/gtk_runtime.cr`: keep the GTK loop and GC finalizers on the original
  application thread; use this entry point instead of the generated `app.run`.
- `src/i18n.cr`: gettext integration; initial languages are English and German.
- `src/metadata.cr`: application identity, version and embedded icon resources.
- `spec/`: deterministic discovery tests; never depend on the developer's hardware.
- `tests/ui_smoke.cr`: Xvfb navigation, layout and refresh checks.
- `tests/discovery_smoke.cr`: real diagnostic child processes with GTK running;
  keep this regression check independent of installed graphics tools/hardware.
- `scripts/`, `packaging/`: pinned AppImage and standalone Flatpak builds.

Run `make setup` to install shards and generate GI bindings. Generated bindings,
executables, compiled catalogs and build outputs are ignored. Do not copy Disk
View's generated files, Git history, release history or mount-management code.

Keep discovery asynchronous and GTK updates on its main thread. Refresh preserves
the current page. Use `AdwOverlaySplitView` with a breakpoint for responsive
navigation. Missing hardware information must not prevent other sections loading.
Show hardware facts in the UI, without data-source rows or implementation notes
such as where values were read or how shared caches are counted.
CPU and RAM share one unlock state for the lifetime of the window. Present locked
fields blank and disabled, using a pinned AdwBanner with a primary Unlock button;
do not request authorization again on page changes or refresh.
The user-authorized additional-details action may run the fixed read-only
`dmidecode --type 4,17` command via pkexec. Use numeric type IDs; combined keyword
names are not accepted by dmidecode. Keep the GUI unprivileged,
make authorization explicit, cancel on close/timeout and never accept arbitrary
commands or arguments. Do not read raw devices or perform mutating actions.

Keep translatable UI messages translated in every language in `po/LINGUAS`; run
`make generate_locales` after changing messages. `shard.yml` is the version source;
keep the newest AppStream release synchronized. Use English source strings.

Relevant checks:

```sh
make test
make test-packaging
crystal tool format --check src/ spec/ tests/*.cr
make validate-metadata
python3 scripts/packaging.py verify
make build
make test-ui
git diff --check
```

Run `make test-ui` after UI changes; it generates screenshots under `build/`.
When changing dependencies, synchronize `packaging/sources.json` with `shard.lock`.

## GTK4 Crystal binding conventions

### Golden rule for API lookups: do not guess

Crystal GTK4 bindings adapt method names and enforce strict types. Never infer
GTK method names from Python, C or Ruby. The actual generated Crystal classes
and methods are local under `lib/gi-crystal/src/auto/gtk-4.0/` and, for
libadwaita, `lib/gi-crystal/src/auto/adw-1/`. On a compiler error or unclear
signature, inspect those files directly before making the next fix, for example:

```sh
rg 'def set_child|def child=' lib/gi-crystal/src/auto/gtk-4.0/
rg 'activated_signal' lib/gi-crystal/src/auto/gtk-4.0/
```

### Required conventions

1. Use GTK4 only. Use `box.append(widget)`, `window.child = widget` or
   `container.child = widget`, never GTK3 `pack_start`/`add`. Do not use
   `widget.show_all`. Use `Gtk::AlertDialog`/`Adw::AlertDialog` rather than the
   deprecated `Gtk::MessageDialog`/synchronous `dialog.run`.
2. Connect generated signals with `_signal`, not strings such as
   `.connect("clicked")`:
   ```crystal
   button.clicked_signal.connect do
     # Handler
   end
   ```
3. For GObjects such as those returned by `Gtk::Builder`, use generated
   `.cast`/`.cast?`, not a plain Crystal `.as(Gtk::Label)` on a C pointer:
   ```crystal
   label = Gtk::Label.cast(builder["my_label"])
   ```
   Unsafe GVariant/container FFI may instead use the typed wrapper constructor
   with an explicit transfer, as in `src/network.cr`.
4. Custom widgets inherit from the appropriate GTK/libadwaita class and use the
   generated GObject annotations/macros such as `@[GObject::Property]` and
   `@[GObject::Virtual]` for overrides. Do not hand-write C vtables. Do not assume
   an `@[Gtk::UiTemplate]` macro exists in these bindings; verify generated/local
   helpers before use. Verify virtual activation in an application smoke test;
   prefer explicit signal connections for app lifecycle actions.
5. GTK4 is not thread-safe. Never access widgets from background fibers. Return
   all UI updates to the GTK main-loop thread with `GLib.idle_add` (return `false`
   for one-shot callbacks) or a repeating main-loop source that receives worker
   results. Raw discovery workers need `Fiber::ExecutionContext::Isolated`.
   ```crystal
   GLib.idle_add do
     label.text = result
     false
   end
   ```

After every code change run `crystal build src/system-view.cr --no-codegen`.
`src/main.cr` is not this project's entry point. Read the complete compiler
output, including expected/actual types, use `--error-trace` when needed, and
inspect the generated signatures before making the next change.

## Releases

The full procedure is in [doc/packaging.md](doc/packaging.md#github-releases).
When the user requests a release:

1. Inspect Git status/diff, remote state, existing tags/releases and CI. Choose an
   unused numeric version (no `v` prefix).
2. Update `shard.yml`, prepend a dated `CHANGELOG.md` entry and add matching
   AppStream release notes in all supported languages. Preserve history.
3. Run the checks above and locally test affected package builds.
4. Commit the intended changes and push to `master`; wait for `Linux packages`
   on that exact commit to pass both package jobs.
5. Create/push an annotated numeric version tag on that tested commit. Publish
   with `gh release create --verify-tag`, an explicit title and release notes.
6. Watch the release-triggered run with `gh run watch RUN_ID --exit-status`.
7. Verify the published release contains versioned x86_64 `.AppImage`, `.flatpak`
   and a separate `.sha256` for each. Return the URL and accurate CI/asset status.

Ordinary pushes/PRs/manual runs only upload workflow artifacts. Published
releases trigger automatic asset uploads after both package jobs pass. CI does
not publish to Flathub. Commits, tags and publication require a user request.
