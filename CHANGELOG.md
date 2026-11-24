# Changelog

## 0.4.1 - 2026-11-24

- Add a signed Flatpak repository for updates through compatible software managers.
- Keep standalone Flatpak bundles and the AppImage available as direct downloads.

## 0.4.0 - 2026-11-22

- Bundle application icons for a consistent appearance across systems.
- Publish standalone Flatpak bundles for ARM64 as well as x86_64.

## 0.3.4 - 2026-11-20

- Improve repeated Disk View launches from the AppImage.
- Show the Disk View shortcut in Flatpak when its host desktop entry is available.

## 0.3.3 - 2026-11-20

- Add interface translations for 42 additional languages and localize the application metadata.
- Avoid passing System View's AppImage library and GTK paths when opening Disk View.
- Expand the README with user-facing installation and usage information.

## 0.3.2 - 2026-11-19

- Enable the authorized processor and memory details query in Flatpak using host-installed tools.
- Place custom hardware icons in the icon theme so they follow the active appearance.

## 0.3.1 - 2026-11-19

- Include OpenGL and Vulkan diagnostic tools in the Flatpak package.
- Make XWayland available for OpenGL diagnostics in Wayland sessions.
- Recognize identical duplicate Vulkan device reports when a device UUID is available.
- Add a screenshot to the AppStream metadata and clarify Flatpak installation.
- Highlight the AppImage and Flatpak downloads in the README.

## 0.3.0 - 2026-11-19

- Show missing software and installation guidance on the summary and affected
  pages, with distribution-specific package suggestions.
- Add package guidance for Arch, Debian, Ubuntu, Fedora, openSUSE and NixOS.
- Hide GNOME Settings shortcuts when the settings service is unavailable.
- Add a Disk View shortcut on the Drives page when its desktop entry is available.
- Support NixOS paths for the optional processor and memory details action.
- Document runtime requirements and move development instructions to CONTRIBUTING.md.

## 0.2.0 - 2026-11-18

- Expand the hardware overview with monitors, audio, video, input devices,
  network, Bluetooth, printers, power supplies and sensors.
- Show available live CPU and GPU readings, memory usage, battery status and
  sensor values, with manual refresh for hardware changes.
- Add drive health, boot security, runtime environment and detailed graphics
  information where reported by the system.
- Open relevant GNOME Settings panels from hardware and system sections.
- Add optional authorization for additional processor and memory details on
  native and AppImage installations.
- Improve adaptive layouts, navigation and clipboard exports, and add an option
  to start the application in English.
- Publish the first AppImage and standalone Flatpak packages.

## 0.1.0 - 2026-11-16

- Add a system overview with processor, mainboard, graphics, RAM and drive models.
- Add adaptive sidebar navigation and six initial hardware/system detail pages.
- Read Linux system information asynchronously without administrator privileges.
- Add English/German localization and a custom GNOME-style application icon.
- Adopt Disk View's pinned AppImage/Flatpak packaging and GitHub release workflow.
