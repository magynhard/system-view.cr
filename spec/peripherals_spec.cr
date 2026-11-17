require "spec"
require "./support/fixture_files"

describe "peripheral discovery" do
  it "decodes connected monitor identity, dimensions and preferred timing" do
    monitor = SystemView::Inventory.scan(FixtureFiles.new).monitors.first
    monitor.vendor.should eq("Dell")
    monitor.model.should eq("ExamplePanel")
    monitor.product_id.should eq("1234")
    monitor.connector.should eq("DP-1")
    monitor.width_mm.should eq(600)
    monitor.height_mm.should eq(340)
    monitor.preferred_mode.should eq("1920 × 1080")
    monitor.preferred_hz.should be_close(60.0, 0.01)
    monitor.modes.should eq(["1920x1080", "1280x720"])
    monitor.active.should be_true
  end

  it "rejects invalid EDID checksums and truncated data without losing connector information" do
    invalid = FixtureFiles.edid
    invalid[10] ^= 1_u8
    {invalid, Bytes[0, 255], Bytes.empty}.each do |bytes|
      monitor = SystemView::Inventory.monitor_from_edid("HDMI-A-1", bytes, ["1920x1080"], false)
      monitor.model.should be_empty
      monitor.vendor.should be_empty
      monitor.preferred_hz.should eq(0)
      monitor.connector.should eq("HDMI-A-1")
      monitor.modes.should eq(["1920x1080"])
    end
  end

  it "excludes disconnected outputs and handles absent hardware gracefully" do
    files = FixtureFiles.new
    SystemView::Inventory.scan(files).monitors.size.should eq(1)
    files.files.clear
    files.directories.clear
    data = SystemView::Inventory.scan(files)
    data.monitors.should be_empty
    data.audio.should be_empty
    data.inputs.should be_empty
    data.processor.flags.should be_empty
  end

  it "lists ALSA audio cards and codec names without opening sound devices" do
    audio = SystemView::Inventory.scan(FixtureFiles.new).audio
    audio.size.should eq(1)
    audio.first.name.should eq("Example USB Audio")
    audio.first.driver.should eq("USB-Audio")
    audio.first.codecs.should eq(["Example Codec"])
  end

  it "classifies keyboards and mice but excludes power buttons" do
    inputs = SystemView::Inventory.scan(FixtureFiles.new).inputs
    inputs.map(&.kind).should eq(["keyboard", "mouse"])
    inputs.map(&.name).should eq(["Example Keyboard", "Example Mouse"])
    inputs.first.bus.should eq("USB")
    inputs.first.vendor_id.should eq("1234")
  end

  it "recognizes gamepads by joystick handlers even without cached properties" do
    files = FixtureFiles.new
    files.files["/proc/bus/input/devices"] = "I: Bus=0005 Vendor=1234 Product=5678 Version=0001\nN: Name=\"Example Gamepad\"\nH: Handlers=js0 event9\n"
    input = SystemView::Inventory.scan(files).inputs.first
    input.kind.should eq("gamepad")
    input.bus.should eq("Bluetooth")
  end

  it "prefers touchpad classification over generic mouse compatibility" do
    files = FixtureFiles.new
    files.files["/sys/class/input/event4/dev"] = "13:68"
    files.files["/run/udev/data/c13:68"] = "E:ID_INPUT_MOUSE=1\nE:ID_INPUT_TOUCHPAD=1\n"
    SystemView::Inventory.scan(files).inputs.last.kind.should eq("touchpad")
  end

  it "reports only CPU flags shared by all logical processors" do
    files = FixtureFiles.new
    files.files["/proc/cpuinfo"] = "processor: 0\nflags: fpu mmx avx2\n\nprocessor: 1\nflags: fpu mmx\n"
    SystemView::Inventory.scan(files).processor.flags.should eq(["fpu", "mmx"])
  end

  it "reads configured and supported memory-module voltages" do
    files = FixtureFiles.new
    files.files["/run/udev/data/+dmi:id"] += "E:MEMORY_DEVICE_0_CONFIGURED_VOLTAGE=1.35\nE:MEMORY_DEVICE_0_MINIMUM_VOLTAGE=1.2\nE:MEMORY_DEVICE_0_MAXIMUM_VOLTAGE=1.35\n"
    mod = SystemView::Inventory.scan(files).memory.modules.first
    mod.voltage.should eq(1.35)
    mod.minimum_voltage.should eq(1.2)
    mod.maximum_voltage.should eq(1.35)
    files.files["/run/udev/data/+dmi:id"] += "E:MEMORY_DEVICE_0_CONFIGURED_VOLTAGE=1\n"
    SystemView::Inventory.scan(files).memory.modules.first.voltage.should eq(0)
  end
end
