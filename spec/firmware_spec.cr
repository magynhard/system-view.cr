require "spec"
require "../src/firmware"

describe SystemView::Firmware do
  it "uses the numeric processor and memory types accepted by dmidecode" do
    SystemView::FirmwareQuery::DMI_ARGUMENTS.should eq({"--type", "4,17"})
  end

  it "runs only the fixed authorized query on the host when sandboxed" do
    SystemView::FirmwareQuery.command("/usr/bin/pkexec", "/usr/bin/dmidecode", true).should eq(
      ["flatpak-spawn", "--host", "--watch-bus", "--env=LC_ALL=C", "--env=LANG=C", "/usr/bin/pkexec", "--disable-internal-agent", "/usr/bin/dmidecode", "--type", "4,17"])
    SystemView::FirmwareQuery.command("/usr/bin/pkexec", "/usr/bin/dmidecode", false).should eq(
      ["/usr/bin/pkexec", "--disable-internal-agent", "/usr/bin/dmidecode", "--type", "4,17"])
  end
  it "extracts processor socket, voltage, clocks, flags and characteristics" do
    text = "Handle 0x0016, DMI type 4, 48 bytes\nProcessor Information\n\tSocket Designation: AM4\n\tVoltage: 1.1 V\n\tExternal Clock: 100 MHz\n\tMax Speed: 4650 MHz\n\tCurrent Speed: 3400 MHz\n\tUpgrade: Socket AM4\n\tFlags:\n\t\tMMX (MMX technology supported)\n\t\tSSE2 (Streaming SIMD extensions 2)\n\tCharacteristics:\n\t\t64-bit capable\n\t\tMulti-Core\n"
    data = SystemView::Firmware.parse(text)
    cpu = data.processors.first
    cpu.socket.should eq("AM4")
    cpu.voltage.should eq("1.1 V")
    cpu.external_clock.should eq("100 MHz")
    cpu.maximum_clock.should eq("4650 MHz")
    cpu.configured_clock.should eq("3400 MHz")
    cpu.upgrade.should eq("Socket AM4")
    cpu.capabilities.size.should eq(2)
    cpu.characteristics.should eq(["64-bit capable", "Multi-Core"])
  end

  it "reads precise DIMM voltages and ignores empty slots and unrelated structures" do
    text = "Handle 0x0001, DMI type 17, 40 bytes\nMemory Device\n\tSize: 16 GB\n\tLocator: DIMM 0\n\tBank Locator: P0 CHANNEL A\n\tConfigured Voltage: 1.200 V\n\tMinimum Voltage: 1.200 V\n\tMaximum Voltage: 1.350 V\nHandle 0x0002, DMI type 17, 40 bytes\n\tSize: No Module Installed\nHandle 0x0003, DMI type 1, 40 bytes\n\tSerial Number: not-collected\n"
    memory = SystemView::Firmware.parse(text).memory
    memory.size.should eq(1)
    memory.first.voltage.should eq("1.200 V")
    memory.first.maximum_voltage.should eq("1.350 V")
    memory.first.slot.should eq("DIMM 0")
  end

  it "handles missing and unsupported processor data without inventing values" do
    SystemView::Firmware.parse("").processors.should be_empty
    cpu = SystemView::Firmware.parse("Handle 0x0016, DMI type 4, 48 bytes\nProcessor Information\n").processors.first
    cpu.socket.should be_empty
    cpu.capabilities.should be_empty
  end

  it "keeps all four supplied DIMM banks distinct and retains their 1.2 V values" do
    text = { {"P0 CHANNEL A", "DIMM 0"}, {"P0 CHANNEL A", "DIMM 1"}, {"P0 CHANNEL B", "DIMM 0"}, {"P0 CHANNEL B", "DIMM 1"} }.map_with_index do |(bank, slot), index|
      "Handle 0x00#{index}, DMI type 17, 40 bytes\nMemory Device\n\tSize: 16 GiB\n\tLocator: #{slot}\n\tBank Locator: #{bank}\n\tManufacturer: Unknown\n\tPart Number: CMK32GX4M2E3200C16  \n\tMinimum Voltage: 1.2 V\n\tMaximum Voltage: 1.2 V\n\tConfigured Voltage: 1.2 V\n"
    end.join
    modules = SystemView::Firmware.parse(text).memory
    modules.size.should eq(4)
    modules.map { |mod| {mod.bank, mod.slot} }.uniq.size.should eq(4)
    modules.each do |mod|
      mod.voltage.should eq("1.2 V")
      mod.minimum_voltage.should eq("1.2 V")
      mod.maximum_voltage.should eq("1.2 V")
      mod.part_number.should eq("CMK32GX4M2E3200C16")
      mod.manufacturer.should be_empty
    end
  end
end
