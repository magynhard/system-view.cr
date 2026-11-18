require "spec"
require "../src/printers"

describe SystemView::PrinterDiscovery do
  it "lists configured printers from CUPS output" do
    output = %[ ["Office", "Laser", "Office"] ]
    result = SystemView::PrinterDiscovery.scan(-> { output.as(String?) })
    result.available.should be_true
    result.names.should eq(["Laser", "Office"])
  end

  it "distinguishes an empty list from unavailable printer information" do
    SystemView::PrinterDiscovery.scan(-> { "[]".as(String?) }).available.should be_true
    result = SystemView::PrinterDiscovery.scan(-> { nil.as(String?) })
    result.available.should be_false
    result.names.should be_empty
    SystemView::PrinterDiscovery.scan(-> { "invalid".as(String?) }).available.should be_false
  end
end
