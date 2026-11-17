require "../../src/inventory"

class FixtureFiles < SystemView::LinuxFiles
  getter files = {} of String => String
  getter directories = {} of String => Array(String)
  getter links = {} of String => String

  def initialize
    super("/", false)
    @files["/etc/os-release"] = "NAME=Linux\nPRETTY_NAME=\"Example Linux 1.0\"\n"
    @files["/proc/sys/kernel/hostname"] = "workstation"
    @files["/proc/sys/kernel/osrelease"] = "6.18.0-example"
    @files["/proc/cpuinfo"] = (0..3).map { |i| "processor : #{i}\nmodel name : Example CPU 9000\nvendor_id : ExampleVendor\ncpu family : 25\nmodel : 33\nstepping : 2\nflags : fpu mmx sse sse2 avx2\n" }.join("\n")
    @files["/proc/meminfo"] = "MemTotal: 32000000 kB\nMemAvailable: 16000000 kB\nSwapTotal: 8000000 kB\n"
    @files["/proc/uptime"] = "189234.54 356780.12\n"
    @files["/run/udev/data/+dmi:id"] = "E:MEMORY_ARRAY_NUM_DEVICES=4\nE:MEMORY_ARRAY_MAX_CAPACITY=137438953472\n" +
                                       (0..1).map { |i| "E:MEMORY_DEVICE_#{i}_SIZE=17179869184\nE:MEMORY_DEVICE_#{i}_LOCATOR=DIMM #{i}\nE:MEMORY_DEVICE_#{i}_MANUFACTURER=Example Memory\nE:MEMORY_DEVICE_#{i}_PART_NUMBER=TEST-16G-DDR4\nE:MEMORY_DEVICE_#{i}_TYPE=DDR4\nE:MEMORY_DEVICE_#{i}_CONFIGURED_SPEED_MTS=3200\nE:MEMORY_DEVICE_#{i}_CONFIGURED_VOLTAGE=1.35\nE:MEMORY_DEVICE_#{i}_MINIMUM_VOLTAGE=1.2\nE:MEMORY_DEVICE_#{i}_MAXIMUM_VOLTAGE=1.35\n" }.join +
                                       "E:MEMORY_DEVICE_2_PRESENT=0\nE:MEMORY_DEVICE_3_PRESENT=0\n"
    @directories["/sys/devices/system/cpu"] = (0..3).map { |i| "cpu#{i}" } + ["cpufreq"]
    4.times do |i|
      base = "/sys/devices/system/cpu/cpu#{i}/topology"
      @files["#{base}/physical_package_id"] = "0"
      @files["#{base}/core_id"] = (i // 2).to_s
      frequency = "/sys/devices/system/cpu/cpu#{i}/cpufreq"
      @files["#{frequency}/cpuinfo_min_freq"] = "2200000"
      @files["#{frequency}/cpuinfo_max_freq"] = "4600000"
      @files["#{frequency}/base_frequency"] = "3400000"
      @files["#{frequency}/scaling_cur_freq"] = i.even? ? "2800000" : "3400000"
      @files["#{frequency}/scaling_available_frequencies"] = "3400000 2800000 2200000"
      @files["#{frequency}/scaling_driver"] = "example-cpufreq"
      @files["#{frequency}/scaling_governor"] = "ondemand"
      cache_root = "/sys/devices/system/cpu/cpu#{i}/cache"
      @directories[cache_root] = ["index0", "index1", "index2", "index3", "uevent"]
      { {1, "Data", "32K"}, {1, "Instruction", "32K"}, {2, "Unified", "512K"}, {3, "Unified", "32768K"} }.each_with_index do |(level, kind, size), index|
        cache = "#{cache_root}/index#{index}"
        @files["#{cache}/level"] = level.to_s
        @files["#{cache}/type"] = kind
        @files["#{cache}/size"] = size
        @files["#{cache}/id"] = level == 3 ? "0" : (i // 2).to_s
        @files["#{cache}/shared_cpu_list"] = level == 3 ? "0-3" : (i < 2 ? "0-1" : "2-3")
        @files["#{cache}/coherency_line_size"] = "64"
        @files["#{cache}/ways_of_associativity"] = level == 3 ? "16" : "8"
      end
    end
    @files["/sys/devices/system/cpu/cpufreq/boost"] = "1"
    @files["/sys/class/dmi/id/board_vendor"] = "Example Boards"
    @files["/sys/class/dmi/id/board_name"] = "Board X570"
    @files["/sys/class/dmi/id/bios_version"] = "1.20"
    @directories["/sys/bus/pci/devices"] = ["0000:01:00.0", "0000:02:00.0", "0000:03:00.0"]
    {"0000:01:00.0" => {"0x030000", "0x1234", "0xabcd"},
     "0000:02:00.0" => {"0x030200", "0x5678", "0x0001"},
     "0000:03:00.0" => {"0x020000", "0x1234", "0x2222"}}.each do |address, values|
      base = "/sys/bus/pci/devices/#{address}"
      @files["#{base}/class"], @files["#{base}/vendor"], @files["#{base}/device"] = values
    end
    @links["/sys/bus/pci/devices/0000:01:00.0/driver"] = "examplegpu"
    @files["/sys/bus/pci/devices/0000:01:00.0/mem_info_vram_total"] = "8000000000"
    @files["/usr/share/hwdata/pci.ids"] = "# PCI database\n1234  Example Graphics\n\tabcd  Exact GPU 5000\n\t\t1234 0000  Subsystem\n5678  Second Vendor\n\t0001  Integrated GPU\n"
    @directories["/sys/block"] = ["nvme0n1", "sda", "dm-0", "loop0", "zram0", "md0", "sr0"]
    @directories["/sys/block/nvme0n1/device"] = [] of String
    @files["/sys/block/nvme0n1/device/model"] = "Example NVMe 1TB"
    @files["/sys/block/nvme0n1/size"] = "1953125000"
    @files["/sys/block/nvme0n1/queue/logical_block_size"] = "4096"
    @directories["/sys/block/sda/device"] = [] of String
    @files["/sys/block/sda/device/model"] = "Example HDD 2TB"
    @files["/sys/block/sda/size"] = "3906250000"
    @files["/sys/block/sda/queue/rotational"] = "1"
    {"dm-0", "loop0", "zram0", "md0", "sr0"}.each do |device|
      @directories["/sys/block/#{device}/device"] = [] of String
      @files["/sys/block/#{device}/size"] = "1953125000"
    end
    @directories["/sys/class/drm"] = ["card0", "card0-DP-1", "card0-HDMI-A-1"]
    @files["/sys/class/drm/card0-DP-1/status"] = "connected"
    @files["/sys/class/drm/card0-DP-1/enabled"] = "enabled"
    @files["/sys/class/drm/card0-DP-1/modes"] = "1920x1080\n1280x720\n1920x1080"
    @files["/sys/class/drm/card0-DP-1/edid"] = String.new(self.class.edid)
    @files["/sys/class/drm/card0-HDMI-A-1/status"] = "disconnected"
    @files["/proc/asound/cards"] = " 0 [USBTest        ]: USB-Audio - Example USB Audio\n                      Example Audio at USB\n"
    @directories["/proc/asound/card0"] = ["codec#0"]
    @files["/proc/asound/card0/codec#0"] = "Codec: Example Codec\nAddress: 0"
    @files["/proc/bus/input/devices"] = "I: Bus=0003 Vendor=1234 Product=5678 Version=0001\nN: Name=\"Example Keyboard\"\nH: Handlers=kbd event3\n\nI: Bus=0003 Vendor=4321 Product=8765 Version=0001\nN: Name=\"Example Mouse\"\nH: Handlers=mouse0 event4\n\nI: Bus=0019 Vendor=0000 Product=0001 Version=0000\nN: Name=\"Power Button\"\nH: Handlers=kbd event0\n"
    @files["/sys/class/input/event3/dev"] = "13:67"
    @files["/run/udev/data/c13:67"] = "E:ID_INPUT_KEYBOARD=1\n"
  end

  def self.edid : Bytes
    data = Bytes.new(128, 0_u8)
    data[0, 8].copy_from(Bytes[0, 255, 255, 255, 255, 255, 255, 0])
    data[8], data[9], data[10], data[11] = 0x10_u8, 0xac_u8, 0x34_u8, 0x12_u8
    data[21], data[22] = 60_u8, 34_u8
    data[54, 8].copy_from(Bytes[0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40])
    data[75] = 0xfc_u8
    data[77, 13].copy_from("ExamplePanel\n".to_slice)
    data[127] = ((256 - data.sum(0) { |byte| byte.to_i } % 256) % 256).to_u8
    data
  end

  def read(path : String) : String
    @files[path]? || ""
  end

  def read_bytes(path : String) : Bytes
    read(path).to_slice.dup
  end

  def children(path : String) : Array(String)
    @directories[path]? || [] of String
  end

  def exists?(path : String) : Bool
    @files.has_key?(path) || @directories.has_key?(path)
  end

  def link_name(path : String) : String
    @links[path]? || ""
  end
end
