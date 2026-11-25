# Contributing

## Development setup

Building from source requires Crystal **1.21+**, Shards, GTK **4.12+**,
libadwaita **1.5+**, GObject Introspection, gettext, pkg-config and C build tools.

On Arch Linux / Manjaro:

```sh
sudo pacman -S --needed crystal shards gtk4 libadwaita gobject-introspection \
  gettext pkgconf base-devel gc pcre2 libyaml hwdata appstream desktop-file-utils
```

On Debian / Ubuntu 24.04 or newer:

```sh
sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev \
  libgirepository1.0-dev gobject-introspection libgc-dev libpcre2-dev libyaml-dev \
  gettext pci.ids appstream desktop-file-utils
```

Install a compatible Crystal compiler and Shards separately if needed. Then run:

```sh
make setup
make run
```

`make setup` installs dependencies and generates the GTK bindings. `make build`
creates `bin/system-view`; `make install PREFIX="$HOME/.local"` installs it for
your user.

To start the application in English regardless of the system language:

```sh
SYSTEM_VIEW_LANGUAGE=en ./bin/system-view
```

To test the missing optional software notice and its details dialog:

```sh
SYSTEM_VIEW_TEST_MISSING_TOOLS=1 ./bin/system-view
```

This simulates missing optional tools and libraries for both the notice and the
affected features. Other hardware discovery remains available.

## Building packages

See the [packaging guide](doc/packaging.md) for building and testing AppImage
and Flatpak packages, publishing GitHub releases, and maintaining the signed
Flatpak repository.

## Checks

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

The UI tests require Xvfb, `xvfb-run` and `dbus-run-session` and save screenshots
under `build/`. Translation catalogs are in `po/`; run `make generate_locales`
after changing translatable messages.
