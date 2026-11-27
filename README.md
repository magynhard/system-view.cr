<div align="center">
  <img src="data/icons/de.magynhard.SystemView.svg" width="96" height="96" alt="System View icon">
</div>

# System View

[![GitHub Release](https://img.shields.io/github/v/release/magynhard/system-view.cr?style=plastic&color=blue&label=GitHub&logo=github)](https://github.com/magynhard/system-view.cr/releases)
[![Crystal](https://img.shields.io/badge/_-Crystal-Sub?style=plastic&color=gray&logo=crystal&logoColor=white)](https://crystal-lang.org/)
[![GTK](https://img.shields.io/badge/_-GTK4-Sub?style=plastic&color=gray&logo=gtk&logoColor=green)](https://www.gtk.org/)
[![libadwaita](https://img.shields.io/badge/_-libadwaita-Sub?style=plastic&color=gray&logo=gnome&logoColor=white)](https://gnome.pages.gitlab.gnome.org/libadwaita/)
[![Linux](https://img.shields.io/badge/_-Linux-Sub?style=plastic&color=gray&logo=linux&logoColor=white)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-gold.svg?style=plastic&logo=mit)](LICENSE)

System View is a native Linux application for exploring your computer's hardware
and system information. It brings your components, connected devices and useful
live readings together in a simple GTK4 and libadwaita interface.

> If you want a quick, easy-to-understand overview of what's inside your computer
> and what's connected to it, System View is for you.

![System View showing the hardware summary in dark mode](doc/screenshot.png)

## Download and install

### Install Flatpak from the signed repository

Available for x86_64 and ARM64. Both methods below let you receive updates
through a compatible software manager or `flatpak update`, without downloading
each release manually.

The Flatpak requires Flatpak 1.17 or newer and the GNOME 51 runtime from Flathub.
After installation, open **System View** from your applications menu.

#### Using a software manager

1. Right-click the [System View `.flatpakref` link](https://flatpak.magynhard.de/system-view/de.magynhard.SystemView.flatpakref)
   and choose **Save Link As…**.
2. Double-click the saved file in your file manager and select **Install**.
   You need a software manager with Flatpak support, such as GNOME Software
   with its Flatpak plugin.

#### Using the terminal

```sh
flatpak install --user --from https://flatpak.magynhard.de/system-view/de.magynhard.SystemView.flatpakref
```

### Install standalone packages

**[Download the latest release](https://github.com/magynhard/system-view.cr/releases/latest)**
to install a standalone package. These packages do not receive updates from the
signed repository. To update, download the new release and install the new
Flatpak bundle or replace the old AppImage.

- **AppImage:** Download the `.AppImage` file, make it executable and open it.
  It is available for x86_64 and requires glibc 2.39 or newer.
- **Standalone Flatpak:** Download the `.flatpak` file for x86_64 or ARM64.
  Open it with a software manager that supports Flatpak and select **Install**.

Each standalone package has a separate SHA-256 checksum.

## Features

- Start with a summary of your computer and open a component for more details.
- Explore your processor, graphics cards, mainboard, drives and memory.
- View monitors, audio devices, cameras, keyboards, mice and printers.
- Check network connections, Bluetooth devices, power supplies and sensors.
- See operating system, desktop environment and runtime information.
- Watch available values such as processor and graphics clocks, memory usage,
  temperatures and battery status update automatically.
- Copy the summary or all information, refresh the inventory, and open relevant
  GNOME Settings panels from the application.
- Use a responsive interface that follows your system's light or dark appearance
  and supports English and German.

The information shown depends on your hardware, drivers and system. Values that
cannot be determined are shown as unknown or not reported.

## Components at a glance

| Section | What you can see |
| --- | --- |
| Graphics | Graphics cards, video memory, clocks, load and graphics API details |
| Processor | Processor model, cores, threads, clocks and caches |
| Mainboard | Mainboard, firmware, boot mode and security information |
| Drives | Physical drives, capacity, connection and available health information |
| Memory | Installed and available memory, swap and memory module details |
| Monitors | Connected displays, resolution and refresh rates |
| Audio | Audio devices, the active sound server and default input and output |
| Cameras | Detected cameras and other video capture devices |
| Input Devices | Keyboards, mice, touchpads, game controllers and other input devices |
| Network | Ethernet and Wi-Fi connections, addresses and connection details |
| Bluetooth | Adapters and paired or connected devices |
| Operating System | Linux distribution, kernel, desktop and runtime environment |
| Power | Power adapters and battery status, charge and health |
| Sensors | Available temperature and fan readings |
| Printers | Printers configured with CUPS |

Standard information is read without administrator privileges. On native and
AppImage installations, you can choose to unlock additional processor and memory
details through the system's authorization dialog. This optional action is not
available in the standalone Flatpak.

## Requirements

Linux and a graphical session are required. The AppImage supports x86_64 and
requires glibc 2.39 or newer. The Flatpak supports x86_64 and ARM64 and requires
Flatpak 1.17 or newer and the GNOME 51 runtime. Optional tools and services
provide additional hardware information.

For native and AppImage installations, the following optional packages provide
OpenGL/Vulkan diagnostics, audio session details, printer information and the
authorization tools for additional processor and memory details. Coreutils
provides the `timeout` command used for background queries.

```sh
# Arch Linux / Manjaro
sudo pacman -S --needed mesa-utils vulkan-tools libpulse coreutils dmidecode polkit libcups

# Debian / Ubuntu
sudo apt install mesa-utils vulkan-tools pulseaudio-utils coreutils dmidecode pkexec libcups2

# Fedora
sudo dnf install glx-utils vulkan-tools pulseaudio-utils coreutils dmidecode polkit cups-libs

# openSUSE
sudo zypper install Mesa-demo-x vulkan-tools pulseaudio-utils coreutils dmidecode polkit libcups2
```

On NixOS, add `pkgs.mesa-demos`, `pkgs.vulkan-tools`, `pkgs.pulseaudio`,
`pkgs.coreutils`, `pkgs.dmidecode` and `pkgs.cups` to your
`environment.systemPackages`, then apply your configuration with
`sudo nixos-rebuild switch`. Additional firmware details also need
`security.polkit.enable` and a graphical authentication agent. The CUPS library
must be accessible to the application at runtime. Running the AppImage on NixOS
may require additional compatibility setup; the standalone Flatpak is an
alternative. The Flatpak includes `glxinfo` and `vulkaninfo`; it cannot use
diagnostic tools installed only on the host.

## Run

To build and run from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

To start the application in English regardless of the system language:

```sh
SYSTEM_VIEW_LANGUAGE=en ./bin/system-view
```

Use the header bar to copy information, refresh or open the About dialog.

| Shortcut | Action |
| --- | --- |
| Ctrl+R | Refresh hardware information |
| F9 | Show or hide the sidebar |
| F1 | About System View |
| Ctrl+W | Close the window |

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and checks.

## Author and license

Created by [Matthäus J. N. Beyrle](https://github.com/magynhard).
Released under the [MIT License](LICENSE).
