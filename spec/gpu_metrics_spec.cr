require "spec"
require "./support/fixture_files"

describe SystemView::Inventory do
  it "keeps current and maximum PCIe links and device metrics distinct" do
    gpu = SystemView::Inventory.graphics(FixtureFiles.new).first
    gpu.pcie_current.should eq("PCIe 3.0 · 8.0 GT/s · x8")
    gpu.pcie_maximum.should eq("PCIe 4.0 · 16.0 GT/s · x16")
    gpu.utilization.should eq(27.0)
    gpu.power_watts.should eq(42.5)
  end

  it "handles partial or invalid links and missing sensor values" do
    SystemView::Inventory.pcie_link("unknown", "16").should eq("x16")
    SystemView::Inventory.pcie_link("16.0 GT/s PCIe", "-1").should eq("PCIe 4.0 · 16.0 GT/s")
    SystemView::Inventory.pcie_link("", "").should be_empty
    SystemView::Inventory.gpu_utilization("101").should be_nil
    SystemView::Inventory.gpu_utilization("0").should eq(0.0)
    SystemView::Inventory.gpu_power(FixtureFiles.new, "/missing").should be_nil
  end
end
