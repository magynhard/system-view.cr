require "spec"
require "./support/network_fixture"
require "../src/drive_health"

describe SystemView::DriveHealthDiscovery do
  it "reads cached ATA health without probing disks" do
    bus = FixtureNetworkBus.new
    bus.properties[{"/org/freedesktop/UDisks2/block_devices/sda", "org.freedesktop.UDisks2.Block"}] = "({'Drive': <objectpath '/drive/a'>},)"
    bus.properties[{"/drive/a", "org.freedesktop.UDisks2.Drive.Ata"}] = "({'SmartSupported': <true>, 'SmartEnabled': <true>, 'SmartUpdated': <uint64 123>, 'SmartFailing': <false>, 'SmartTemperature': <303.15>, 'SmartPowerOnSeconds': <uint64 72000>},)"
    drives = SystemView::Inventory.scan(FixtureFiles.new).drives
    result = SystemView::DriveHealthDiscovery.scan(drives, bus).find { |drive| drive.name == "sda" }.not_nil!
    result.health.failing.should be_false
    result.health.temperature.not_nil!.should be_close(30.0, 0.01)
    result.health.power_on_hours.should eq(20_u64)
    result.health.updated_at.should eq(123_u64)
    bus.calls.select { |call| call[0] == "org.freedesktop.UDisks2" }.all? { |call| call[2] == "GetAll" }.should be_true
  end

  it "does not claim uninitialized SMART data is healthy" do
    ata = SystemView::NetworkValue.new(GLib::Variant.parse("{'SmartSupported': <true>, 'SmartEnabled': <true>, 'SmartUpdated': <uint64 0>, 'SmartFailing': <false> }"))
    SystemView::DriveHealthDiscovery.parse(ata, nil).failing.should be_nil
  end

  it "reads cached NVMe warnings and temperature" do
    nvme = SystemView::NetworkValue.new(GLib::Variant.parse("{'SmartUpdated': <uint64 123>, 'SmartCriticalWarning': <['degraded']>, 'SmartTemperature': <uint16 308>, 'SmartPowerOnHours': <uint64 500> }"))
    health = SystemView::DriveHealthDiscovery.parse(nil, nvme)
    health.failing.should be_true
    health.temperature.not_nil!.should be_close(34.85, 0.01)
    health.power_on_hours.should eq(500_u64)
  end

  it "matches NVMe health using the block device's drive object" do
    bus = FixtureNetworkBus.new
    bus.properties[{"/org/freedesktop/UDisks2/block_devices/nvme0n1", "org.freedesktop.UDisks2.Block"}] = "({'Drive': <objectpath '/drive/nvme'>},)"
    bus.properties[{"/drive/nvme", "org.freedesktop.UDisks2.NVMe.Controller"}] = "({'SmartUpdated': <uint64 123>, 'SmartCriticalWarning': <@as []>, 'SmartTemperature': <uint16 300>, 'SmartPowerOnHours': <uint64 10>},)"
    drive = SystemView::Inventory.scan(FixtureFiles.new).drives.find { |item| item.name == "nvme0n1" }.not_nil!
    result = SystemView::DriveHealthDiscovery.scan([drive], bus).first
    result.health.failing.should be_false
    result.health.power_on_hours.should eq(10_u64)
  end
end
