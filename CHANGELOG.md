# Changelog

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
