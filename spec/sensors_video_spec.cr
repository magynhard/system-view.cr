require "spec"
require "./support/fixture_files"

describe SystemView::Inventory do
  it "reads labelled temperatures and fan speeds without guessing their components" do
    files = FixtureFiles.new
    sensors = SystemView::Inventory.sensors(files)
    sensors.find { |sensor| sensor.kind == "temp" }.not_nil!.value.should eq(42.5)
    sensors.find { |sensor| sensor.kind == "temp" }.not_nil!.label.should eq("CPU Package")
    sensors.find { |sensor| sensor.kind == "fan" }.not_nil!.value.should eq(1200.0)
    files.files["/sys/class/hwmon/hwmon0/temp1_input"] = "invalid"
    files.files["/sys/class/hwmon/hwmon0/fan1_input"] = "-1"
    SystemView::Inventory.sensors(files).all?(&.value.nil?).should be_true
  end

  it "updates sensor values while preserving the existing inventory" do
    files = FixtureFiles.new
    data = SystemView::Inventory.scan(files)
    files.files["/sys/class/hwmon/hwmon0/temp1_input"] = "51000"
    updated = SystemView::Inventory.live_snapshot(files, data)
    updated.sensors.find { |sensor| sensor.kind == "temp" }.not_nil!.value.should eq(51.0)
    updated.video_devices.should eq(data.video_devices)
  end

  it "lists capture devices without claiming metadata endpoints are cameras" do
    files = FixtureFiles.new
    devices = SystemView::Inventory.video_devices(files)
    devices.map(&.name).should eq(["Example Camera"])
    devices.first.device.should eq("/dev/video0")
    devices.first.kind.should eq("capture")
    files.files.delete("/run/udev/data/c81:0")
    SystemView::Inventory.video_devices(files).first.kind.should be_empty
  end
end
