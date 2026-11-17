# System View

A native Linux hardware overview built with **Crystal, GTK4 and libadwaita**.
Inspired by [Disk View](https://github.com/magynhard/disk-view.cr), with the same
build and packaging foundations.

## Features

- Open directly to an overview of your processor, mainboard, graphics cards,
  installed RAM and physical drives, including exact model names where available.
- Explore Graphics, Processor, Mainboard, Drives, Memory, Monitors, Audio,
  Input Devices, Network and Operating System pages.
- Keep navigation alongside the content on wide windows. Below 860 pixels it
  becomes an overlay, accessible with the sidebar button or **F9**.
- Read standard hardware information without root privileges. Load additional
  processor and memory details through explicit desktop authorization when needed.
- Follow the system's light/dark appearance and language (English and German).
- Use a custom, embedded GNOME-style application icon, also in standalone builds.
- Open hardware/system sections directly by activating their overview rows.
- See RAM generation, monitor summaries and the active desktop version in the overview.

## Development

Requires Crystal **1.21+**, Shards, GTK **4.12+**, libadwaita **1.5+**,
GObject Introspection, gettext, pkg-config and the usual C build dependencies.
Install the distribution's PCI ID database for human-readable graphics names.
AMD model identification additionally uses libdrm's `amdgpu.ids` database.

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

Install a compatible Crystal compiler and Shards separately if your distribution
ships an older version, then:

```sh
make setup
make run
```

The executable is `bin/system-view`. Install with `make install PREFIX=~/.local`
or `sudo make install`; remove it with the matching `make uninstall` command.

### Checks

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

`make test-ui` needs Xvfb, `xvfb-run` and `dbus-run-session`. It checks the default
selection, all detail pages, narrow/wide navigation, refresh and closing during
discovery. Screenshots are generated under `build/system-view-*.png`.
It also runs a separate startup regression with actual diagnostic child processes
and deterministic tool output. This catches subprocess/scheduler deadlocks that
injected graphics parsers/loaders cannot detect.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+R | Refresh hardware information |
| F9 | Show/hide sidebar |
| F1 | About System View |
| Ctrl+W | Close window |

## Hardware discovery

`src/inventory.cr` contains the GTK-independent data model and Linux reader.
Discovery runs in a background thread; widgets are updated on GTK's main thread.
Refresh keeps the selected page. The application only reads system information.

| Component | Sources |
| --- | --- |
| Processor | `/proc/cpuinfo`, CPU topology, cpufreq clocks and cache hierarchy in `/sys/devices/system/cpu` |
| Mainboard / BIOS | Readable DMI attributes in `/sys/class/dmi/id` |
| Graphics | PCI display controllers in `/sys/bus/pci/devices`, `pci.ids`, libdrm `amdgpu.ids` and optional driver-reported product names |
| RAM | Cached udev/SMBIOS module sizes in `/run/udev/data/+dmi:id`; `/proc/meminfo` for usable and available memory |
| Drives | Physical block devices in `/sys/block`, cached udev model/vendor/transport properties; sizes use 512-byte kernel sectors |
| System | `os-release`, kernel version, hostname and computer model |
| Monitors | Connected DRM outputs and validated base EDID blocks |
| Audio | ALSA card and codec metadata in `/proc/asound` |
| Input devices | `/proc/bus/input/devices` and cached udev classification, without opening event devices |
| LAN / Wi-Fi | Physical interfaces in `/sys/class/net`, cached udev identification and read-only NetworkManager D-Bus properties |
| Bluetooth | BlueZ adapter and paired/connected-device properties, with a sysfs adapter fallback |

RAM, swap and video memory use 1024-based IEC units (GiB, MiB); drive capacities
use decimal GB/TB. Kernel-usable RAM excludes reserved memory and may be below
installed-module capacity. Driver-reported VRAM may also exclude a reserved part.

Installed RAM is the primary capacity in the overview and on the RAM page. It is
summed from the cached module sizes, with usable/available memory shown separately.
The RAM page also lists readable slot labels, manufacturers, series, module part
numbers, types and configured data rates in MT/s. `data/ram-identifiers.json`
embeds the supplied 43-prefix manufacturer/series mapping with longest-prefix
matching. Explicit manufacturer data takes priority; the mapping does not infer
RAM generation or form factor. Missing or incomplete firmware-cache sizes leave
installed capacity Unknown; the application never rounds usable memory to guess it
and never substitutes the motherboard's maximum supported capacity.

CPU details include family/model/stepping, reported minimum/maximum/base clocks,
the current clock range, available frequency steps, driver, governor and boost
state. Clock values are snapshots taken on refresh, not live telemetry. Missing
base clocks remain Unknown. L1 data/instruction and L2/L3 caches show instance
count, per-instance size, total size, cache-line size and associativity. Shared
caches are deduplicated by cache identity or shared CPU list, including under SMT.

GPU details distinguish the GPU vendor, card manufacturer, board model and PCI
model group. AMD device **and revision** IDs are matched against `amdgpu.ids` to
identify variants sharing the same device ID. Driver product names take priority.
A generic PCI model group is not claimed as an exact model. Subsystem IDs
identify card vendors and board variants when the local
database contains them. A retail edition is not guessed from VRAM capacity.

Graphics details also show the active GPU and video-memory clock when exposed by
the driver. Optional `glxinfo` (`mesa-utils` on Debian/Ubuntu, `mesa-utils` on Arch)
and `vulkaninfo` (`vulkan-tools`) diagnostics provide OpenGL, GLSL, OpenGL ES and
the physical GPU's Vulkan API version/driver. Each command has a two-second
timeout. Child-process communication uses GIO in the discovery worker so stdout
and process completion do not depend on Crystal fibers blocked by GTK's main
loop. The same mechanism is used for the explicit firmware query. OpenGL
attribution requires a hardware-accelerated renderer with matching
PCI IDs; ambiguous identical cards/ICDs and software renderers are not attributed
to physical cards. Missing tools, unsupported diagnostics or failed queries leave
these fields **Not reported**, not an assertion that the API is unsupported.
The Flatpak does not execute host tools; optional diagnostic tools must be
available inside its runtime to report API versions.

The interface presents hardware facts without data-source rows or implementation
explanations. Drive identification prefers complete cached model strings;
protocol names such as ATA/USB are not treated as manufacturers. Explicit model
brand prefixes identify common vendors when ATA metadata omits the manufacturer.
Connection type (such as SATA or USB) is displayed separately.

CPU socket count means the number of processor packages, not a socket type such
as AM4. Processor Features lists the additional processor capabilities after
unlocking. The optional additional-details
action supplies socket designation/type, voltage, configured/external clocks,
capabilities and module voltages from `dmidecode`.

### Additional hardware details

On native/AppImage installations, install `dmidecode`, `pkexec` (polkit) and a
desktop authentication agent. The CPU and RAM pages show an **AdwBanner** with
**Some hardware details are locked** and a primary **Unlock…** button. Protected
fields are already visible, blank and disabled. Unlocking starts only the fixed command
`pkexec --disable-internal-agent /usr/bin/dmidecode --type 4,17`
(using the installed system dmidecode path). The GUI itself stays unprivileged.
Numeric DMI types 4 and 17 select processors and memory devices. Compound keyword
arguments such as `processor,memory` are not supported by dmidecode.
Nothing is authorized automatically on startup or refresh. Cancellation and a
120-second timeout stop the request. One successful unlock enables both CPU and
RAM details, hides both banners, and survives page changes and refresh until the
window closes. Cancelling or failing authorization leaves the placeholders locked.

The standalone Flatpak does not expose this privileged action or gain host-command
execution permissions. Its regular inventory and module identification remain
available; protected fields stay disabled. Unlocking currently requires a
native/AppImage launch.

Monitor groups are numbered **Monitor 1**, **Monitor 2**, etc., with **(Primary)**
only when reported by the compositor. On GNOME, a bounded read-only Mutter query
provides current resolution/refresh rate and the numbering order used by GNOME
Settings (built-in panels first). Those values are separate from preferred EDID
timings. With no supported compositor, stable local numbering is used and primary
status/current timing are not guessed. Repeated connector names across GPUs must
be unambiguously matched; HDMI-A connector aliases are normalized. The graphics
page links attached monitors, including available current refresh rates.
Missing EDID data leaves identity fields Unknown while
retaining the connector and advertised modes. Audio includes HDMI/DP, onboard and
USB cards; input classification includes keyboards, mice, gamepads and touch devices.

Missing or inaccessible values appear as **Unknown**. Graphics without a matching
PCI database entry retain their PCI IDs. Non-PCI graphics are not collected yet.
Direct SPD data and live utilization graphs are future work. Standard discovery
reads cached/system metadata without raw-device access. Older udev caches can
round module voltages to whole volts; these imprecise entries are left Unknown
until additional firmware details are loaded.
Virtual mappings, loop devices, software RAID aggregates, optical drives and
empty removable media are excluded to avoid counting physical capacity twice.
Virtual machines report the hardware exposed by their hypervisor.

Memory is named **Memory** throughout navigation and in the overview. When every
installed module has the same known manufacturer and exact part number, their
common manufacturer/series/model precede capacity in the summary. Incomplete,
mixed or unidentified module sets do not claim a shared model. The overview hero
subtitle contains only the operating-system name.

Each module has a CL–tRCD–tRP–tRAS timings row. Standard SMBIOS and its udev cache
do not provide these timings, so they are currently **Not reported**. The app
does not infer active timings from a part-number suffix or a vendor's advertised
profile and does not probe raw SPD devices.

### Network

The Network page and its overview shortcut list Ethernet (LAN), Wi-Fi when
present, and Bluetooth adapters. Each network interface has its own connection
status, profile, negotiated link speed in Mbit/s or Gbit/s, MAC/permanent MAC,
MTU and driver. LAN also reports duplex. IPv4 and IPv6 groups show addresses with
prefix lengths, address configuration, DHCP, gateway, DNS servers and search
domains, without mixing settings from different interfaces. An automatic IPv6
profile alone does not prove DHCPv6 is in use: SLAAC is also possible.

Wi-Fi adds the active SSID, BSSID, signal strength, frequency and advertised
security. Bluetooth lists power/discoverability/pairing state, reported version,
address, paired/connected devices and available RSSI. BlueZ does not expose a
negotiated link bitrate, so Bluetooth speed is shown as **Not reported**, never
inferred from the Bluetooth version. Link speeds are not internet speed tests.

Discovery only reads existing state: no Wi-Fi scans, Bluetooth discovery,
connections or configuration changes. NetworkManager/BlueZ are optional;
physical links and adapters remain visible without them, while unavailable
configuration is Unknown rather than inferred from a global resolver file.
Refresh reloads the state in the background. GTK and wrapper finalization stay
on the original application thread, including when discovery triggers garbage
collection.

## Packaging and CI

```sh
make appimage
make flatpak
```

AppImage uses an Ubuntu 24.04 container; Flatpak uses GNOME 51 and requires
Flatpak 1.17+. Build prerequisites, sandbox access and the release procedure are
documented in [doc/packaging.md](doc/packaging.md).

GitHub Actions builds x86_64 AppImage and standalone Flatpak packages on pushes,
pull requests, manual runs and published releases. Only published-release runs
attach the packages and their SHA-256 files to GitHub Releases. The workflow
becomes active when this project is pushed to its own GitHub repository.

## License

[MIT](LICENSE).
