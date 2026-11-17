require "spec"
require "../src/ram_identity"

describe SystemView::RamIdentifiers do
  it "identifies the supplied Corsair modules from their part-number prefix" do
    identity = SystemView::RamIdentifiers.identify(" CMK32GX4M2E3200C16  ", "Unknown")
    identity.manufacturer.should eq("Corsair")
    identity.series.should eq("Vengeance LPX")
  end

  it "matches the longest prefix first, case-insensitively" do
    SystemView::RamIdentifiers.identify("bls8g4d240fsa").series.should eq("Ballistix Sport")
    SystemView::RamIdentifiers.identify("BL8G36C16U4B").series.should eq("Ballistix")
    SystemView::RamIdentifiers.identify("CMSX32GX4M2A3200C22").series.should eq("Vengeance SODIMM")
  end

  it "preserves explicit manufacturers and leaves unknown prefixes unresolved" do
    identity = SystemView::RamIdentifiers.identify("UNLISTED-16GB", "Example Memory")
    identity.manufacturer.should eq("Example Memory")
    identity.series.should be_empty
    SystemView::RamIdentifiers.identify("UNLISTED-16GB", "Unknown").manufacturer.should be_empty
  end

  it "contains all supplied prefixes and only manufacturer and series fields" do
    raw = JSON.parse({{read_file("#{__DIR__}/../data/ram-identifiers.json")}}).as_h
    raw.size.should eq(43)
    raw.each_value { |entry| entry.as_h.keys.sort.should eq(["manufacturer", "series"]) }
    {"M378A" => "Samsung", "HMCG" => "SK Hynix", "MTA" => "Micron", "KF4" => "Kingston",
     "CP" => "Crucial", "F5-" => "G.Skill", "AD4S" => "ADATA"}.each do |prefix, manufacturer|
      SystemView::RamIdentifiers.identify("#{prefix}EXAMPLE").manufacturer.should eq(manufacturer)
    end
  end
end
