require "spec"
require "./support/fixture_files"

describe "drive identification" do
  it "never presents transport names or numeric PCI IDs as manufacturers" do
    {"ATA", "SATA", "USB", "NVMe", "SCSI", "0x144d", "Generic", "Unknown"}.each do |vendor|
      properties = {"ID_VENDOR" => vendor}
      SystemView::Inventory.drive_vendor("Unidentified model", properties, vendor).should be_empty
    end
    SystemView::Inventory.drive_vendor("Unidentified model", {"ID_VENDOR_FROM_DATABASE" => "Example Storage"}, "ATA").should eq("Example Storage")
  end

  it "uses complete cached ATA models and keeps manufacturer separate from SATA" do
    files = FixtureFiles.new
    files.files["/sys/block/sda/dev"] = "8:0"
    files.files["/sys/block/sda/device/vendor"] = "ATA"
    files.files["/sys/block/sda/queue/rotational"] = "0"
    {
      {"KINGSTON\\x20SA400S37960G\\x20", "KINGSTON SA400S37960G", "Kingston"},
      {"Samsung\\x20SSD\\x20870\\x20EVO\\x201TB", "Samsung SSD 870 EVO 1TB", "Samsung"},
    }.each do |encoded, model, vendor|
      files.files["/run/udev/data/b8:0"] = "E:ID_MODEL_ENC=#{encoded}\nE:ID_BUS=ata\nE:ID_ATA_SATA=1\n"
      drive = SystemView::Inventory.scan(files).drives.find { |item| item.name == "sda" }.not_nil!
      drive.model.should eq(model)
      drive.vendor.should eq(vendor)
      drive.connection.should eq("SATA")
      drive.kind.should eq("SSD")
    end
  end

  it "uses explicit vendor metadata but never substitutes a transport name" do
    SystemView::Inventory.drive_vendor("Unrecognized model", {"ID_VENDOR" => "Storage_Company"}, "ATA").should eq("Storage Company")
    SystemView::Inventory.drive_vendor("Unrecognized model", {"ID_VENDOR_FROM_DATABASE" => "Example Storage Inc."}, "USB").should eq("Example Storage Inc.")
    {"ATA", "SATA", "USB", "NVMe", "SCSI", "Generic", "0x144d", ""}.each do |vendor|
      SystemView::Inventory.drive_vendor("Unrecognized model", {} of String => String, vendor).should be_empty
    end
    SystemView::Inventory.drive_vendor("Kingstonish disk", {} of String => String, "ATA").should be_empty
  end

  it "recognizes brands in sysfs models when the cache is unavailable" do
    files = FixtureFiles.new
    files.files["/sys/block/sda/device/model"] = "Samsung SSD 870"
    files.files["/sys/block/sda/device/vendor"] = "ATA"
    drive = SystemView::Inventory.scan(files).drives.find { |item| item.name == "sda" }.not_nil!
    drive.vendor.should eq("Samsung")
    drive.model.should eq("Samsung SSD 870")
  end

  it "falls back to non-encoded cached models and preserves USB transport" do
    files = FixtureFiles.new
    files.files["/sys/block/sda/dev"] = "8:0"
    files.files["/run/udev/data/b8:0"] = "E:ID_MODEL=SanDisk_3.2Gen1\nE:ID_VENDOR=USB\nE:ID_BUS=usb\n"
    drive = SystemView::Inventory.scan(files).drives.find { |item| item.name == "sda" }.not_nil!
    drive.model.should eq("SanDisk 3.2Gen1")
    drive.vendor.should eq("SanDisk")
    drive.connection.should eq("USB")
  end
end
