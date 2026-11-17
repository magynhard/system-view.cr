require "spec"
require "./support/fixture_files"
require "./support/network_fixture"
require "../src/export"
require "../src/firmware"

private def sample_snapshot : SystemView::Snapshot
  data = SystemView::Inventory.scan(FixtureFiles.new, desktop: "GNOME 50.5",
    connectivity: SystemView::NetworkDiscovery.scan(network_files, FixtureNetworkBus.new))
  gpu = data.graphics.first
  monitor = data.monitors.first
  data.copy_with(graphics: [gpu.copy_with(clock_mhz: 1800_u64, memory_clock_mhz: 1124_u64, opengl: "4.6", glsl: "4.60", opengl_es: "3.2", vulkan: "1.3.280", vulkan_driver: "Example driver")],
    monitors: [monitor.copy_with(graphics_address: gpu.address, current_mode: "1920 × 1080", current_hz: 75.0, number: 1, primary: true)])
end

describe SystemView::SnapshotExport do
  it "writes an English overview report independent of the UI locale" do
    text = SystemView::SnapshotExport.overview(sample_snapshot)
    text.should start_with("# System View — workstation")
    text.should contain("## Overview")
    text.should contain("### Hardware overview")
    text.should contain("- **Processor:** Example CPU 9000\n  - 2 cores · 4 threads")
    text.should contain("- **Mainboard:** Example Boards Board X570")
    text.should contain("- **Graphics:** Example Graphics · Example Graphics Exact GPU 5000 · 7.5 GiB")
    text.should contain("- **Memory:** Example Memory · TEST-16G-DDR4 · 32.0 GiB · DDR4")
    text.should contain("- **Storage:** Example NVMe 1TB · 1.0 TB")
    # Bluetooth adapters state their power state, not a bare yes/no.
    text.should contain("- **Network:** Ethernet (LAN) · enp1s0 · Connected · 2.5 Gbit/s · 192.0.2.10\n  - Ethernet (LAN) · enp2s0 · Disconnected\n  - Wi-Fi · wlan0 · Connected · Test ä · 866.7 Mbit/s\n  - Bluetooth · Example Bluetooth · Active")
    text.should contain("- **Operating System:** Example Linux 1.0")
    text.should contain("- **Uptime:** 2 d 4 h 33 min")
    # German locale must not leak into the export.
    text.should_not contain("Aktiv")
    text.should_not contain("Laufzeit")
  end

  it "writes a full report covering every detail page" do
    firmware = SystemView::Firmware.parse("Handle 0x0016, DMI type 4, 48 bytes\nProcessor Information\n\tSocket Designation: AM4\n\tVoltage: 1.1 V\n\tExternal Clock: 100 MHz\n\tCurrent Speed: 3400 MHz\n\tMax Speed: 4650 MHz\n\tUpgrade: Socket AM4\nHandle 0x0017, DMI type 17, 40 bytes\nMemory Device\n\tSize: 16 GB\n\tLocator: DIMM 0\n\tManufacturer: Unknown\n\tPart Number: CMK32GX4M2E3200C16\n\tConfigured Voltage: 1.2 V\n")
    text = SystemView::SnapshotExport.full(sample_snapshot, firmware)
    {"## Graphics", "## Processor", "## Mainboard", "## Drives", "## Memory", "## Monitors",
     "## Audio", "## Input Devices", "## Network", "## Operating System"}.each do |heading|
      text.should contain(heading)
    end
    text.should contain("- **Operating System:** Example Linux 1.0\n- **Kernel:** 6.18.0-example\n- **Desktop Environment:** GNOME 50.5\n- **Hostname:** workstation\n- **Uptime:** 2 d 4 h 33 min")
    text.should contain("### Example Graphics Exact GPU 5000")
    text.should contain("- **Current GPU clock:** 1800 MHz")
    text.should contain("- **OpenGL:** 4.6")
    text.should contain("- **Vulkan:** 1.3.280")
    text.should contain("- **Connected monitors:** Monitor 1 (Primary) · DP-1 · 1920 × 1080 · 75.0 Hz")
    text.should contain("### Processor 1")
    text.should contain("- **Socket:** AM4")
    text.should contain("- **Voltage:** 1.1 V")
    text.should contain("- **Base clock:** 3.4 GHz")
    text.should contain("- **L3 cache (Data and instructions):** 1 × 32.0 MiB · 32.0 MiB total")
    text.should contain("### Firmware\n- **BIOS version:** 1.20")
    text.should contain("- **Manufacturer:** Example Boards\n- **Model:** Board X570")
    text.should contain("### Example NVMe 1TB")
    text.should contain("- **Removable:** No")
    text.should contain("### DIMM 0")
    text.should contain("- **Model:** Example Memory Vengeance LPX · CMK32GX4M2E3200C16\n  - 16.0 GiB · DDR4 · 3200 MT/s")
    text.should contain("- **Voltage:** 1.2 V")
    text.should contain("### Monitor 1 (Primary)")
    text.should contain("- **Current refresh rate:** 75.0 Hz")
    text.should contain("### Example USB Audio")
    text.should contain("### Example Keyboard")
    text.should contain("### Ethernet (LAN) · enp1s0")
    text.should contain("### enp1s0 · IPv4")
    text.should contain("- **IP addresses:** 192.0.2.10/24")
    text.should contain("- **DNS servers:** 192.0.2.53\n  - 192.0.2.54")
    text.should contain("### enp1s0 · IPv6")
    text.should contain("### Bluetooth · hci0")
    text.should contain("- **Enabled:** Yes")
    text.should contain("- **Bluetooth version:** 5.3")
    text.should contain("### Bluetooth · Headphones")
    text.should contain("- **Signal strength:** -48 dBm")
  end

  it "omits empty values and tolerates missing sections" do
    files = FixtureFiles.new
    files.files.clear
    files.directories.clear
    data = SystemView::Inventory.scan(files)
    text = SystemView::SnapshotExport.full(data, nil)
    text.should start_with("# System View — Unknown system")
    text.should contain("- **Uptime:** Unknown")
    text.should contain("- **Display controller:** Unknown")
    text.should_not contain("- **Manufacturer:** \n")
    text.should_not contain("**:** \n")
  end
end
