require "spec"
require "./support/fixture_files"

describe "processor details" do
  it "reports family/model/stepping and converts no frequency units during discovery" do
    cpu = SystemView::Inventory.scan(FixtureFiles.new).processor
    cpu.family.should eq("25")
    cpu.model_id.should eq("33")
    cpu.stepping.should eq("2")
    cpu.clocks.base_khz.should eq(3_400_000)
    cpu.clocks.minimum_khz.should eq(2_200_000)
    cpu.clocks.maximum_khz.should eq(4_600_000)
    cpu.clocks.current_min_khz.should eq(2_800_000)
    cpu.clocks.current_max_khz.should eq(3_400_000)
    cpu.clocks.steps_khz.should eq([3_400_000_u64, 2_800_000_u64, 2_200_000_u64])
    cpu.clocks.driver.should eq("example-cpufreq")
    cpu.clocks.governor.should eq("ondemand")
    cpu.clocks.boost.should be_true
  end

  it "prefers measured cpuinfo frequency and leaves unavailable base clock unknown" do
    files = FixtureFiles.new
    4.times do |index|
      base = "/sys/devices/system/cpu/cpu#{index}/cpufreq"
      files.files["#{base}/cpuinfo_cur_freq"] = "4000000"
      files.files.delete("#{base}/base_frequency")
    end
    clocks = SystemView::Inventory.scan(files).processor.clocks
    clocks.current_min_khz.should eq(4_000_000)
    clocks.current_max_khz.should eq(4_000_000)
    clocks.base_khz.should eq(0)
  end

  it "does not invent clocks or boost state when cpufreq is unavailable" do
    files = FixtureFiles.new
    files.files.keys.select(&.includes?("/cpufreq/")).each { |path| files.files.delete(path) }
    clocks = SystemView::Inventory.scan(files).processor.clocks
    clocks.minimum_khz.should eq(0)
    clocks.maximum_khz.should eq(0)
    clocks.current_min_khz.should eq(0)
    clocks.boost.should be_nil
  end

  it "counts private caches per core and a shared L3 only once despite SMT" do
    caches = SystemView::Inventory.scan(FixtureFiles.new).processor.caches
    caches.size.should eq(4)
    l1_data = caches.find { |cache| cache.level == 1 && cache.kind == "Data" }.not_nil!
    l1_instruction = caches.find { |cache| cache.level == 1 && cache.kind == "Instruction" }.not_nil!
    l2 = caches.find { |cache| cache.level == 2 }.not_nil!
    l3 = caches.find { |cache| cache.level == 3 }.not_nil!
    l1_data.instances.should eq(2)
    l1_instruction.instances.should eq(2)
    l1_data.bytes.should eq(32 * 1024)
    l2.instances.should eq(2)
    l2.bytes.should eq(512 * 1024)
    l3.instances.should eq(1)
    l3.bytes.should eq(32 * 1024 * 1024)
    l3.line_bytes.should eq(64)
    l3.ways.should eq(16)
  end

  it "deduplicates by shared CPU lists if cache IDs are not provided" do
    files = FixtureFiles.new
    files.files.keys.select { |path| path.includes?("/cache/") && path.ends_with?("/id") }.each { |path| files.files.delete(path) }
    caches = SystemView::Inventory.scan(files).processor.caches
    caches.find { |cache| cache.level == 3 }.not_nil!.instances.should eq(1)
    caches.find { |cache| cache.level == 2 }.not_nil!.instances.should eq(2)
  end

  it "ignores malformed and overflowing cache capacities" do
    files = FixtureFiles.new
    {"invalid", "#{UInt64::MAX}G"}.each do |size|
      4.times { |index| files.files["/sys/devices/system/cpu/cpu#{index}/cache/index3/size"] = size }
      SystemView::Inventory.scan(files).processor.caches.any? { |cache| cache.level == 3 }.should be_false
    end
  end
end

describe "installed memory" do
  it "summarizes a common manufacturer and exact model only for complete identical modules" do
    memory = SystemView::Inventory.memory(FixtureFiles.new)
    modules = memory.modules.map { |mod| mod.copy_with(manufacturer: "Corsair", series: "Vengeance LPX", part_number: "CMK32GX4M2E3200C16") }
    memory = memory.copy_with(modules: modules)
    SystemView::Inventory.common_memory_model(memory).should eq("Corsair Vengeance LPX · CMK32GX4M2E3200C16")
    SystemView::Inventory.common_memory_model(memory.copy_with(installed: 0_u64)).should be_empty
    SystemView::Inventory.common_memory_model(memory.copy_with(modules: modules.first(1))).should be_empty
    modules[1] = modules[1].copy_with(part_number: "OTHER-MODEL")
    SystemView::Inventory.common_memory_model(memory.copy_with(modules: modules)).should be_empty
    modules[1] = modules[0].copy_with(manufacturer: "Other")
    SystemView::Inventory.common_memory_model(memory.copy_with(modules: modules)).should be_empty
  end

  it "sums installed module bytes and ignores maximum array capacity and empty slots" do
    memory = SystemView::Inventory.scan(FixtureFiles.new).memory
    memory.installed.should eq(32_u64 * 1024 ** 3)
    memory.total.should eq(32_768_000_000_u64)
    memory.modules.size.should eq(2)
    memory.modules.first.part_number.should eq("TEST-16G-DDR4")
    memory.modules.first.kind.should eq("DDR4")
    memory.modules.first.speed_mts.should eq(3200)
    memory.modules.first.slot.should eq("DIMM 0")
  end

  it "does not round usable memory to guess an installed capacity" do
    files = FixtureFiles.new
    files.files.delete("/run/udev/data/+dmi:id")
    memory = SystemView::Inventory.scan(files).memory
    memory.installed.should eq(0)
    memory.modules.should be_empty
    memory.total.should eq(32_768_000_000_u64)
  end

  it "does not report partial module totals as installed memory" do
    files = FixtureFiles.new
    files.files["/run/udev/data/+dmi:id"] = "E:MEMORY_ARRAY_NUM_DEVICES=2\nE:MEMORY_DEVICE_0_SIZE=34359738368\n"
    memory = SystemView::Inventory.scan(files).memory
    memory.installed.should eq(0)
    memory.modules.size.should eq(1)
  end

  it "rejects overflow, invalid slot counts and inconsistent firmware totals" do
    files = FixtureFiles.new
    {
      "E:MEMORY_ARRAY_NUM_DEVICES=2\nE:MEMORY_DEVICE_0_SIZE=#{UInt64::MAX}\nE:MEMORY_DEVICE_1_SIZE=1\n",
      "E:MEMORY_ARRAY_NUM_DEVICES=99999999\n",
      "E:MEMORY_ARRAY_NUM_DEVICES=-1\n",
      "E:MEMORY_ARRAY_NUM_DEVICES=1\nE:MEMORY_DEVICE_0_SIZE=1024\n",
      "E:MEMORY_ARRAY_NUM_DEVICES=1\nE:MEMORY_DEVICE_0_SIZE=-1\n",
    }.each do |properties|
      files.files["/run/udev/data/+dmi:id"] = properties
      SystemView::Inventory.scan(files).memory.installed.should eq(0)
    end
  end
end
