require "spec"
require "./support/fixture_files"

describe SystemView::Inventory do
  it "reads battery and adapter snapshots and estimates charging time" do
    power = SystemView::Inventory.power_supply(FixtureFiles.new)
    power.adapters.size.should eq(1)
    power.adapters.first.online.should be_true
    battery = power.batteries.first
    battery.percent.should eq(80.0)
    battery.full.should eq(45.0)
    battery.design.should eq(50.0)
    battery.unit.should eq("Wh")
    battery.power.should eq(10.0)
    battery.cycles.should eq(123_u64)
    battery.remaining_seconds.should eq(1800_u64)
  end

  it "handles discharge, charge-based devices, invalid values and device batteries" do
    files = FixtureFiles.new
    base = "/sys/class/power_supply/BAT0"
    files.files["#{base}/status"] = "Discharging"
    SystemView::Inventory.power_supply(files).batteries.first.remaining_seconds.should eq(14_400_u64)
    {"energy_full", "energy_full_design", "energy_now", "power_now"}.each { |name| files.files.delete("#{base}/#{name}") }
    files.files["#{base}/charge_full"] = "4000000"
    files.files["#{base}/charge_full_design"] = "5000000"
    files.files["#{base}/charge_now"] = "2000000"
    files.files["#{base}/current_now"] = "1000000"
    files.files["#{base}/capacity"] = "101"
    battery = SystemView::Inventory.power_supply(files).batteries.first
    battery.unit.should eq("Ah")
    battery.full.should eq(4.0)
    battery.remaining_seconds.should eq(7200_u64)
    battery.percent.should be_nil
    battery.power.should be_nil
    files.files["#{base}/scope"] = "Device"
    SystemView::Inventory.power_supply(files).batteries.should be_empty
    files.files.delete("#{base}/scope")
    files.files["#{base}/present"] = "0"
    SystemView::Inventory.power_supply(files).batteries.should be_empty
    files.files["/sys/class/power_supply/AC/online"] = "bad"
    SystemView::Inventory.power_supply(files).adapters.first.online.should be_nil
  end

  it "does not calculate health from mismatched energy and charge units" do
    files = FixtureFiles.new
    base = "/sys/class/power_supply/BAT0"
    files.files.delete("#{base}/energy_full_design")
    files.files["#{base}/charge_full_design"] = "5000000"
    battery = SystemView::Inventory.power_supply(files).batteries.first
    battery.full.should eq(45.0)
    battery.design.should be_nil
    battery.unit.should eq("Wh")
  end
end
