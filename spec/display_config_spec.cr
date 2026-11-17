require "spec"
require "./support/fixture_files"
require "./support/display_fixture"

describe SystemView::DisplayConfig do
  it "uses GNOME's built-in-first numbering, current mode and logical primary state" do
    data = SystemView::DisplayConfig.parse(display_reply)
    data.map(&.connector).should eq(["eDP-1", "DP-1", "HDMI-1"])
    data.map(&.number).should eq([1, 2, 3])
    data[1].primary.should be_true
    data[1].hz.should eq(75)
    data[1].mode.should eq("1920 × 1080")
    data[2].active.should be_false
    data[2].hz.should eq(0)
  end

  it "keeps current refresh separate from the preferred EDID timing" do
    monitors = SystemView::Inventory.monitors(FixtureFiles.new)
    monitor = SystemView::DisplayConfig.enrich(monitors, display_reply).first
    monitor.number.should eq(2)
    monitor.primary.should be_true
    monitor.current_hz.should eq(75)
    monitor.preferred_hz.should be_close(60, 0.01)
  end

  it "normalizes HDMI-A connector names without confusing serial identities" do
    monitor = SystemView::Inventory.monitors(FixtureFiles.new).first.copy_with(connector: "HDMI-A-1", vendor_code: "ACR", serial: "external")
    monitor = SystemView::DisplayConfig.enrich([monitor], display_reply).first
    monitor.number.should eq(3)
    monitor.primary.should be_false
    monitor.active.should be_false
  end

  it "does not assign ambiguous repeated connectors across graphics cards" do
    monitor = SystemView::Inventory.monitors(FixtureFiles.new).first
    data = SystemView::DisplayConfig.enrich([monitor, monitor.copy_with(graphics_address: "0000:02:00.0")], display_reply)
    data.map(&.number).uniq.size.should eq(2)
    data.all?(&.primary.nil?).should be_true
    data.all?(&.current_hz.zero?).should be_true
  end

  it "uses stable local numbering and leaves primary/current mode unknown without a compositor" do
    monitors = SystemView::Inventory.monitors(FixtureFiles.new)
    monitor = SystemView::DisplayConfig.enrich(monitors, nil).first
    monitor.number.should eq(1)
    monitor.primary.should be_nil
    monitor.current_mode.should be_empty
    monitor.current_hz.should eq(0)
  end
end
