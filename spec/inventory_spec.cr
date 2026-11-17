require "spec"
require "file_utils"
require "./support/fixture_files"

describe SystemView::Inventory do
  it "identifies the processor and counts physical cores independently of threads" do
    cpu = SystemView::Inventory.scan(FixtureFiles.new).processor
    cpu.name.should eq("Example CPU 9000")
    cpu.vendor.should eq("ExampleVendor")
    cpu.cores.should eq(2)
    cpu.threads.should eq(4)
    cpu.sockets.should eq(1)
    cpu.architecture.should_not be_empty
  end

  it "does not invent physical core counts if topology is unavailable" do
    files = FixtureFiles.new
    files.directories["/sys/devices/system/cpu"] = [] of String
    cpu = SystemView::Inventory.scan(files).processor
    cpu.cores.should eq(0)
    cpu.threads.should eq(4)
  end

  it "reads OS names, mainboard identification and kernel memory in bytes" do
    data = SystemView::Inventory.scan(FixtureFiles.new)
    data.os.should eq("Example Linux 1.0")
    data.hostname.should eq("workstation")
    data.mainboard.name.should eq("Board X570")
    data.mainboard.bios_version.should eq("1.20")
    data.memory.total.should eq(32_768_000_000_u64)
    data.memory.available.should eq(16_384_000_000_u64)
    data.memory.swap.should eq(8_192_000_000_u64)
  end

  it "resolves multiple GPU models and excludes non-display PCI devices" do
    graphics = SystemView::Inventory.scan(FixtureFiles.new).graphics
    graphics.map(&.name).should eq(["Example Graphics Exact GPU 5000", "Second Vendor Integrated GPU"])
    graphics.first.driver.should eq("examplegpu")
    graphics.first.memory.should eq(8_000_000_000_u64)
    graphics.first.address.should eq("0000:01:00.0")
  end

  it "preserves PCI identifiers if the local name database is unavailable" do
    files = FixtureFiles.new
    files.files.delete("/usr/share/hwdata/pci.ids")
    SystemView::Inventory.scan(files).graphics.first.name.should eq("PCI 1234:abcd")
  end

  it "identifies AMD variants by device AND revision and reports the board manufacturer separately" do
    files = FixtureFiles.new
    base = "/sys/bus/pci/devices/0000:01:00.0"
    files.files["#{base}/vendor"] = "0x1002"
    files.files["#{base}/device"] = "0x7480"
    files.files["#{base}/revision"] = "0xcf"
    files.files["#{base}/subsystem_vendor"] = "0x1043"
    files.files["#{base}/subsystem_device"] = "0x05fb"
    files.files["/usr/share/hwdata/pci.ids"] = "1002  AMD\n\t7480  Navi 33 family\n\t\t1043 05fb  Example board edition\n1043  ASUSTeK Computer Inc.\n"
    files.files["/usr/share/libdrm/amdgpu.ids"] = "# IDs\n7480, C0, AMD Radeon RX 7600 XT\n7480, CF, AMD Radeon RX 7600\n"
    gpu = SystemView::Inventory.scan(files).graphics.first
    gpu.name.should eq("AMD Radeon RX 7600")
    gpu.model.should eq("AMD Radeon RX 7600")
    gpu.model_group.should eq("AMD Navi 33 family")
    gpu.vendor.should eq("AMD")
    gpu.board_vendor.should eq("ASUSTeK Computer Inc.")
    gpu.board_model.should eq("Example board edition")
    gpu.subsystem_id.should eq("1043:05fb")
    gpu.model_source.amd_database?.should be_true

    files.files["#{base}/revision"] = "0xc0"
    SystemView::Inventory.scan(files).graphics.first.model.should eq("AMD Radeon RX 7600 XT")
    files.files["#{base}/revision"] = "0xff"
    unknown = SystemView::Inventory.scan(files).graphics.first
    unknown.model.should be_empty
    unknown.model_source.unknown?.should be_true
    unknown.name.should eq("Example board edition")
  end

  it "prefers a driver-reported model and does not apply AMD names to another vendor" do
    files = FixtureFiles.new
    base = "/sys/bus/pci/devices/0000:01:00.0"
    files.files["#{base}/device"] = "0x7480"
    files.files["#{base}/revision"] = "0xcf"
    files.files["/usr/share/libdrm/amdgpu.ids"] = "7480, CF, AMD Radeon RX 7600\n"
    SystemView::Inventory.scan(files).graphics.first.model.should be_empty
    files.files["#{base}/product_name"] = "Driver-reported graphics model"
    gpu = SystemView::Inventory.scan(files).graphics.first
    gpu.model.should eq("Driver-reported graphics model")
    gpu.model_source.driver?.should be_true
  end

  it "does not mistake a generic PCI model group for an exact GPU model" do
    gpu = SystemView::Inventory.scan(FixtureFiles.new).graphics.first
    gpu.model.should be_empty
    gpu.board_model.should be_empty
    gpu.model_group.should eq("Example Graphics Exact GPU 5000")
    gpu.model_source.unknown?.should be_true
  end

  it "keeps subsystem names scoped to their parent PCI device" do
    files = FixtureFiles.new
    files.files["/usr/share/hwdata/pci.ids"] = "1234  Example Graphics\n\tabcd  Model A\n\t\t1043 0001  Board A\n\tffff  Model B\n\t\t1043 0001  Board B\n5678  Other Vendor\n\t0001  Model C\n\t\t1043 0001  Board C\n"
    names = SystemView::Inventory.pci_names(files)
    names.subsystems["1234:abcd:1043:0001"].should eq("Board A")
    names.subsystems["1234:ffff:1043:0001"].should eq("Board B")
    names.subsystems["5678:0001:1043:0001"].should eq("Board C")
  end

  it "counts only real drives and uses 512-byte sysfs sectors even on 4K disks" do
    drives = SystemView::Inventory.scan(FixtureFiles.new).drives
    drives.map(&.name).should eq(["nvme0n1", "sda"])
    drives.map(&.bytes).should eq([1_000_000_000_000_u64, 2_000_000_000_000_u64])
    drives.map(&.kind).should eq(["NVMe SSD", "HDD"])
  end

  it "ignores empty removable media and malformed drive capacities" do
    files = FixtureFiles.new
    {"0", "invalid", UInt64::MAX.to_s}.each do |size|
      files.files["/sys/block/sda/size"] = size
      SystemView::Inventory.scan(files).drives.map(&.name).should eq(["nvme0n1"])
    end
  end

  it "tolerates missing sysfs, DMI, procfs and malformed memory values" do
    files = FixtureFiles.new
    files.files.clear
    files.directories.clear
    files.files["/proc/meminfo"] = "MemTotal: garbage\nMemAvailable: #{UInt64::MAX} kB"
    data = SystemView::Inventory.scan(files)
    data.processor.name.should be_empty
    data.memory.total.should eq(0)
    data.memory.available.should eq(0)
    data.drives.should be_empty
    data.graphics.should be_empty
    data.mainboard.name.should be_empty
  end

  it "parses quoted OS values without evaluating shell syntax" do
    fields = SystemView::Inventory.parse_fields("# ignored=x\nNAME='Test=Linux'\nID=test\nBROKEN\n", '=')
    fields.should eq({"NAME" => "Test=Linux", "ID" => "test"})
  end

  it "reads the uptime from procfs and tolerates missing values" do
    data = SystemView::Inventory.scan(FixtureFiles.new)
    data.uptime.should eq(189234.54)
    SystemView::Inventory.uptime_seconds("").should eq(0.0)
    SystemView::Inventory.uptime_seconds("garbage 5").should eq(0.0)
    SystemView::Inventory.uptime_seconds("-3 0").should eq(0.0)
    SystemView::Inventory.uptime_seconds("42.75 99.5").should eq(42.75)
  end
end

describe SystemView::LinuxFiles do
  it "reads from an injected filesystem root and tolerates missing files" do
    root = File.tempname("system-view-fixture", nil)
    begin
      Dir.mkdir_p(File.join(root, "etc"))
      File.write(File.join(root, "etc/os-release"), "test\n")
      files = SystemView::LinuxFiles.new(root, false)
      files.read("/etc/os-release").should eq("test")
      files.read("/missing").should eq("")
      files.children("/missing").should be_empty
      files.link_name("/missing").should eq("")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe "capacity formatting" do
  it "uses base 1024 and binary labels for RAM and video memory" do
    SystemView.format_bytes(68_719_476_736_u64, binary: true).should eq("64.0 GiB")
    SystemView.format_bytes(8_589_934_592_u64, binary: true).should eq("8.0 GiB")
    SystemView.format_bytes(8_573_157_376_u64, binary: true).should eq("8.0 GiB")
    SystemView.format_bytes(1024_u64, binary: true).should eq("1.0 KiB")
  end

  it "uses decimal units for manufacturer capacities" do
    SystemView.format_bytes(1_000_000_000_000_u64).should eq("1.0 TB")
    SystemView.format_bytes(32_000_000_000_u64).should eq("32.0 GB")
    SystemView.format_bytes(999_u64).should eq("999.0 B")
  end

  it "uses 1024-based IEC units for RAM and video memory" do
    SystemView.format_bytes(8_589_934_592_u64, binary: true).should eq("8.0 GiB")
    SystemView.format_bytes(68_719_476_736_u64, binary: true).should eq("64.0 GiB")
    SystemView.format_bytes(1024_u64, binary: true).should eq("1.0 KiB")
    SystemView.format_bytes(1023_u64, binary: true).should eq("1023.0 B")
  end

  it "formats driver/kernel usable amounts without inventing installed capacity" do
    SystemView.format_bytes(8_573_157_376_u64, binary: true).should eq("8.0 GiB")
    SystemView.format_bytes(65_766_416_u64 * 1024, binary: true).should eq("62.7 GiB")
    SystemView.format_bytes(8_573_157_376_u64).should eq("8.6 GB")
  end
end
