require "set"
require "./ram_identity"
require "./network"

module SystemView
  record CpuClocks, minimum_khz : UInt64 = 0_u64, maximum_khz : UInt64 = 0_u64,
    base_khz : UInt64 = 0_u64, current_min_khz : UInt64 = 0_u64, current_max_khz : UInt64 = 0_u64,
    steps_khz : Array(UInt64) = [] of UInt64, driver : String = "", governor : String = "",
    boost : Bool? = nil
  record CpuCache, level : Int32, kind : String, bytes : UInt64, instances : Int32,
    line_bytes : UInt64, ways : Int32
  record Processor, name : String, vendor : String, architecture : String,
    cores : Int32, threads : Int32, sockets : Int32,
    family : String = "", model_id : String = "", stepping : String = "",
    clocks : CpuClocks = CpuClocks.new, caches : Array(CpuCache) = [] of CpuCache,
    flags : Array(String) = [] of String
  record Mainboard, vendor : String, name : String, version : String,
    bios_vendor : String, bios_version : String, bios_date : String,
    boot_mode : String = "", secure_boot : Bool? = nil,
    tpm_present : Bool? = nil, tpm_versions : Array(String) = [] of String
  record GraphicsCard, name : String, vendor_id : String, device_id : String,
    driver : String, address : String, memory : UInt64,
    model : String = "", vendor : String = "", board_vendor : String = "",
    board_model : String = "", model_group : String = "", subsystem_id : String = "",
    revision : String = "", model_source : GraphicsModelSource = GraphicsModelSource::Unknown,
    clock_mhz : UInt64 = 0_u64, memory_clock_mhz : UInt64 = 0_u64,
    opengl : String = "", glsl : String = "", opengl_es : String = "", renderer : String = "",
    vulkan : String = "", vulkan_driver : String = ""
  enum GraphicsModelSource
    Unknown
    Driver
    AmdDatabase
  end
  record PciNames, vendors : Hash(String, String), devices : Hash(String, String),
    subsystems : Hash(String, String)
  record DriveHealth, failing : Bool? = nil, temperature : Float64? = nil,
    power_on_hours : UInt64? = nil, updated_at : UInt64? = nil
  record Drive, name : String, model : String, vendor : String,
    bytes : UInt64, kind : String, removable : Bool, connection : String = "",
    health : DriveHealth = DriveHealth.new
  record MemoryModule, slot : String, bytes : UInt64, part_number : String,
    kind : String, speed_mts : UInt64, voltage : Float64 = 0.0,
    minimum_voltage : Float64 = 0.0, maximum_voltage : Float64 = 0.0,
    manufacturer : String = "", series : String = ""
  record Memory, total : UInt64, available : UInt64, swap : UInt64,
    installed : UInt64 = 0_u64, modules : Array(MemoryModule) = [] of MemoryModule
  record Battery, name : String, vendor : String = "", model : String = "", status : String = "",
    percent : Float64? = nil, full : Float64? = nil, design : Float64? = nil,
    unit : String = "", cycles : UInt64? = nil, power : Float64? = nil, remaining_seconds : UInt64? = nil
  record PowerAdapter, name : String, online : Bool? = nil
  record PowerSupply, batteries : Array(Battery) = [] of Battery, adapters : Array(PowerAdapter) = [] of PowerAdapter
  record Snapshot, hostname : String, os : String, kernel : String,
    product : String, processor : Processor, mainboard : Mainboard,
    graphics : Array(GraphicsCard), drives : Array(Drive), memory : Memory,
    monitors : Array(Monitor) = [] of Monitor, audio : Array(AudioDevice) = [] of AudioDevice,
    inputs : Array(InputDevice) = [] of InputDevice, desktop : String = "",
    connectivity : Connectivity = Connectivity.new, uptime : Float64 = 0.0,
    power_supply : PowerSupply = PowerSupply.new

  # Root injection keeps discovery testable without probing devices or executing
  # external commands. Flatpak host paths are mapped only for read-only discovery.
  class LinuxFiles
    def initialize(@root : String = "/", @sandboxed : Bool = File.file?("/.flatpak-info"))
    end

    def path(path : String) : String
      return File.join(@root, path) unless @root == "/"
      if @sandboxed
        if path == "/etc/os-release"
          return ["/run/host/os-release", "/run/host/etc/os-release", "/run/host/root/etc/os-release"].find { |candidate| File.file?(candidate) } || "/run/host/os-release"
        end
        host = "/run/host/root#{path}"
        return host if File.exists?(host)
      end
      path
    end

    def read(path : String) : String
      File.read(self.path(path)).scrub.strip
    rescue File::Error | IO::Error
      ""
    end

    def children(path : String) : Array(String)
      Dir.children(self.path(path)).sort
    rescue File::Error | IO::Error
      [] of String
    end

    def read_bytes(path : String) : Bytes
      File.read(self.path(path)).to_slice.dup
    rescue File::Error | IO::Error
      Bytes.empty
    end

    def exists?(path : String) : Bool
      File.exists?(self.path(path))
    end

    def link_name(path : String) : String
      File.basename(File.readlink(self.path(path)))
    rescue File::Error | IO::Error
      ""
    end
  end

  module Inventory
    extend self

    ARCHITECTURE = {% if flag?(:x86_64) %}
                     "x86_64"
                   {% elsif flag?(:aarch64) %}
                     "aarch64"
                   {% elsif flag?(:i386) %}
                     "i386"
                   {% elsif flag?(:arm) %}
                     "arm"
                   {% else %}
                     ""
                   {% end %}

    def scan(files = LinuxFiles.new, desktop : String = "", connectivity : Connectivity? = nil) : Snapshot
      os = parse_fields(files.read("/etc/os-release"), '=')
      board = "/sys/class/dmi/id"
      Snapshot.new(
        hostname: files.read("/proc/sys/kernel/hostname"),
        os: os["PRETTY_NAME"]? || os["NAME"]? || "",
        kernel: files.read("/proc/sys/kernel/osrelease"),
        product: [files.read("#{board}/sys_vendor"), files.read("#{board}/product_name")].reject(&.empty?).uniq.join(" "),
        processor: processor(files),
        mainboard: mainboard(files),
        graphics: graphics(files), drives: drives(files),
        memory: memory(files), monitors: monitors(files), audio: audio_devices(files), inputs: input_devices(files), desktop: desktop,
        connectivity: connectivity || NetworkDiscovery.scan(files), uptime: uptime_seconds(files.read("/proc/uptime")),
        power_supply: power_supply(files)
      )
    end

    def power_supply(files : LinuxFiles) : PowerSupply
      batteries = [] of Battery
      adapters = [] of PowerAdapter
      root = "/sys/class/power_supply"
      files.children(root).each do |name|
        path = "#{root}/#{name}"
        next if files.read("#{path}/scope") == "Device"
        case files.read("#{path}/type")
        when "Battery"
          next if files.read("#{path}/present") == "0"
          status = files.read("#{path}/status")
          energy_full = positive_number(files.read("#{path}/energy_full"))
          energy_design = positive_number(files.read("#{path}/energy_full_design"))
          charge_full = positive_number(files.read("#{path}/charge_full"))
          charge_design = positive_number(files.read("#{path}/charge_full_design"))
          energy = energy_full || energy_design
          full = energy ? energy_full : charge_full
          design = energy ? energy_design : charge_design
          unit = energy ? "Wh" : ((charge_full || charge_design) ? "Ah" : "")
          percent = nonnegative_number(files.read("#{path}/capacity"))
          percent = nil if percent && percent > 100
          power = nonnegative_number(files.read("#{path}/power_now"))
          remaining = nil
          current_energy = nonnegative_number(files.read("#{path}/energy_now"))
          if power && power > 0 && current_energy
            amount = status == "Discharging" ? current_energy : (status == "Charging" && energy_full ? {energy_full - current_energy, 0.0}.max : nil)
            seconds = amount.try { |value| value / power * 3600 }
            remaining = seconds.to_u64 if seconds && seconds.finite? && seconds >= 0 && seconds < 31_536_000
          elsif current = positive_number(files.read("#{path}/current_now"))
            charge = nonnegative_number(files.read("#{path}/charge_now"))
            amount = charge ? (status == "Discharging" ? charge : (status == "Charging" && charge_full ? {charge_full - charge, 0.0}.max : nil)) : nil
            seconds = amount.try { |value| value / current * 3600 }
            remaining = seconds.to_u64 if seconds && seconds.finite? && seconds >= 0 && seconds < 31_536_000
          end
          batteries << Battery.new(name, vendor: files.read("#{path}/manufacturer"), model: files.read("#{path}/model_name"),
            status: status, percent: percent, full: full.try { |value| value / 1_000_000 },
            design: design.try { |value| value / 1_000_000 }, unit: unit,
            cycles: files.read("#{path}/cycle_count").to_u64?, power: power.try { |value| value / 1_000_000 }, remaining_seconds: remaining)
        when "Mains", "USB", "USB_C", "USB_PD", "USB_PD_DRP", "BrickID"
          online = case files.read("#{path}/online")
                   when "1" then true
                   when "0" then false
                   else          nil
                   end
          adapters << PowerAdapter.new(name, online)
        end
      end
      PowerSupply.new(batteries, adapters)
    end

    private def nonnegative_number(text : String) : Float64?
      value = text.to_f64?
      value && value.finite? && value >= 0 ? value : nil
    end

    private def positive_number(text : String) : Float64?
      value = nonnegative_number(text)
      value && value > 0 ? value : nil
    end

    def mainboard(files : LinuxFiles) : Mainboard
      board = "/sys/class/dmi/id"
      efi = files.exists?("/sys/firmware/efi")
      boot_mode = efi ? "uefi" : (files.exists?("/sys/firmware") ? "legacy" : "")
      secure_boot = nil
      if efi
        data = files.read_bytes("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c")
        secure_boot = data[4] == 1 if data.size == 5 && data[4] <= 1
      end
      tpm_root = "/sys/class/tpm"
      devices = files.children(tpm_root).select { |name| name.matches?(/^tpm\d+$/) }
      present = devices.empty? ? (files.exists?(tpm_root) ? false : nil) : true
      versions = devices.compact_map do |device|
        case files.read("#{tpm_root}/#{device}/tpm_version_major")
        when "2" then "2.0"
        when "1"
          caps = parse_fields(files.read("#{tpm_root}/#{device}/device/caps"), ':')
          caps["TCG version"]?.presence || "1.x"
        end
      end.uniq
      Mainboard.new(files.read("#{board}/board_vendor"), files.read("#{board}/board_name"),
        files.read("#{board}/board_version"), files.read("#{board}/bios_vendor"),
        files.read("#{board}/bios_version"), files.read("#{board}/bios_date"),
        boot_mode: boot_mode, secure_boot: secure_boot, tpm_present: present, tpm_versions: versions)
    end

    def parse_fields(text : String, separator : Char) : Hash(String, String)
      result = {} of String => String
      text.each_line do |line|
        next if line.starts_with?('#')
        parts = line.split(separator, 2)
        next unless parts.size == 2
        result[parts[0].strip] = parts[1].strip.strip('"').strip('\'')
      end
      result
    end

    def uptime_seconds(text : String) : Float64
      value = text.split(" ").first?.try(&.to_f64?) || 0.0
      value.finite? && value > 0 ? value : 0.0
    end

    def processor(files : LinuxFiles) : Processor
      records = files.read("/proc/cpuinfo").split(/\n\s*\n/).map { |block| parse_fields(block, ':') }.reject(&.empty?)
      first = records.first? || {} of String => String
      cpus = files.children("/sys/devices/system/cpu").select { |name| name.matches?(/^cpu\d+$/) }
      cores = Set(String).new
      sockets = Set(String).new
      cpus.each do |cpu|
        topology = "/sys/devices/system/cpu/#{cpu}/topology"
        socket = files.read("#{topology}/physical_package_id")
        core = files.read("#{topology}/core_id")
        sockets << socket unless socket.empty? || socket == "-1"
        cores << "#{socket}:#{core}" unless core.empty? || core == "-1"
      end
      # Do not claim a logical-thread count is a physical-core count when topology
      # is unavailable (common on non-x86 hardware and restricted containers).
      name = first["model name"]? || first["Hardware"]? || first["Processor"]? || ""
      name = files.read("/sys/firmware/devicetree/base/model").delete('\0') if name.empty?
      flag_sets = records.map { |record| (record["flags"]? || record["Features"]? || "").split }
      flags = flag_sets.empty? ? [] of String : flag_sets.reduce { |common, values| common & values }.uniq.sort
      Processor.new(name, first["vendor_id"]? || first["CPU implementer"]? || "",
        ARCHITECTURE, cores.size,
        records.count { |record| record.has_key?("processor") }, sockets.size,
        family: first["cpu family"]? || "", model_id: first["model"]? || "",
        stepping: first["stepping"]? || "", clocks: cpu_clocks(files, cpus), caches: cpu_caches(files, cpus),
        flags: flags)
    end

    def cpu_clocks(files : LinuxFiles, cpus : Array(String)) : CpuClocks
      minima = [] of UInt64
      maxima = [] of UInt64
      bases = [] of UInt64
      current = [] of UInt64
      steps = [] of UInt64
      drivers = Set(String).new
      governors = Set(String).new
      cpus.each do |cpu|
        base = "/sys/devices/system/cpu/#{cpu}/cpufreq"
        minima << (files.read("#{base}/cpuinfo_min_freq").to_u64? || 0_u64)
        maxima << (files.read("#{base}/cpuinfo_max_freq").to_u64? || 0_u64)
        bases << (files.read("#{base}/base_frequency").to_u64? || 0_u64)
        frequency = files.read("#{base}/cpuinfo_cur_freq").to_u64? || 0_u64
        frequency = files.read("#{base}/scaling_cur_freq").to_u64? || 0_u64 if frequency == 0
        current << frequency
        steps.concat(files.read("#{base}/scaling_available_frequencies").split.compact_map(&.to_u64?))
        driver = files.read("#{base}/scaling_driver")
        governor = files.read("#{base}/scaling_governor")
        drivers << driver unless driver.empty?
        governors << governor unless governor.empty?
      end
      boost = files.read("/sys/devices/system/cpu/cpufreq/boost")
      if boost.empty? && (cpu = cpus.first?)
        boost = files.read("/sys/devices/system/cpu/#{cpu}/cpufreq/boost")
      end
      CpuClocks.new(minimum_khz: minima.reject(&.zero?).min? || 0_u64,
        maximum_khz: maxima.max? || 0_u64, base_khz: bases.reject(&.zero?).min? || 0_u64,
        current_min_khz: current.reject(&.zero?).min? || 0_u64, current_max_khz: current.max? || 0_u64,
        steps_khz: steps.reject(&.zero?).uniq.sort.reverse, driver: drivers.to_a.sort.join(", "),
        governor: governors.to_a.sort.join(", "), boost: boost == "1" ? true : (boost == "0" ? false : nil))
    end

    def cpu_caches(files : LinuxFiles, cpus : Array(String)) : Array(CpuCache)
      seen = Set(String).new
      groups = {} of Tuple(Int32, String, UInt64, UInt64, Int32) => Int32
      cpus.each do |cpu|
        base = "/sys/devices/system/cpu/#{cpu}/cache"
        files.children(base).each do |index|
          next unless index.matches?(/^index\d+$/)
          cache = "#{base}/#{index}"
          level = files.read("#{cache}/level").to_i? || 0
          kind = files.read("#{cache}/type")
          bytes = cache_bytes(files.read("#{cache}/size"))
          next if level <= 0 || kind.empty? || bytes == 0
          id = files.read("#{cache}/id")
          shared = files.read("#{cache}/shared_cpu_list")
          next if id.empty? && shared.empty?
          identity = "#{level}:#{kind}:#{id.empty? ? "cpus=#{shared}" : "id=#{id}"}"
          next unless seen.add?(identity)
          line = files.read("#{cache}/coherency_line_size").to_u64? || 0_u64
          ways = files.read("#{cache}/ways_of_associativity").to_i? || 0
          key = {level, kind, bytes, line, ways}
          groups[key] = (groups[key]? || 0) + 1
        end
      end
      groups.map do |(level, kind, bytes, line, ways), instances|
        CpuCache.new(level, kind, bytes, instances, line, ways)
      end.sort_by { |cache| {cache.level, cache.kind, cache.bytes} }
    end

    private def cache_bytes(text : String) : UInt64
      return 0_u64 unless match = text.match(/^(\d+)([KMG]?)$/)
      value = match[1].to_u64? || 0_u64
      multiplier = case match[2]
                   when "K" then 1024_u64
                   when "M" then 1024_u64 ** 2
                   when "G" then 1024_u64 ** 3
                   else          1_u64
                   end
      value <= UInt64::MAX // multiplier ? value * multiplier : 0_u64
    end

    def memory(files : LinuxFiles) : Memory
      values = parse_fields(files.read("/proc/meminfo"), ':')
      # udev already decoded SMBIOS at boot. Read its cache, never raw firmware
      # or /dev/mem, and never guess installed capacity by rounding MemTotal.
      properties = udev_properties(files, "/run/udev/data/+dmi:id")
      slots = properties["MEMORY_ARRAY_NUM_DEVICES"]?.try(&.to_i?) || 0
      installed = 0_u64
      complete = slots.in?(1..4096)
      modules = [] of MemoryModule
      if complete
        slots.times do |index|
          prefix = "MEMORY_DEVICE_#{index}"
          next if properties["#{prefix}_PRESENT"]? == "0"
          bytes = properties["#{prefix}_SIZE"]?.try(&.to_u64?)
          if bytes.nil? || bytes > UInt64::MAX - installed
            complete = false
            next
          end
          installed += bytes
          next if bytes == 0
          slot = [properties["#{prefix}_BANK_LOCATOR"]?, properties["#{prefix}_LOCATOR"]?].compact.reject(&.empty?).join(" · ")
          part = properties["#{prefix}_PART_NUMBER"]? || ""
          part = "" if {"Unknown", "Not Specified", "<BAD INDEX>"}.includes?(part)
          identity = RamIdentifiers.identify(part, properties["#{prefix}_MANUFACTURER"]? || "")
          modules << MemoryModule.new(slot, bytes, part, properties["#{prefix}_TYPE"]? || "",
            properties["#{prefix}_CONFIGURED_SPEED_MTS"]?.try(&.to_u64?) || 0_u64,
            voltage: cached_voltage(properties["#{prefix}_CONFIGURED_VOLTAGE"]?),
            minimum_voltage: cached_voltage(properties["#{prefix}_MINIMUM_VOLTAGE"]?),
            maximum_voltage: cached_voltage(properties["#{prefix}_MAXIMUM_VOLTAGE"]?),
            manufacturer: identity.manufacturer, series: identity.series)
        end
      end
      usable = kilobytes(values["MemTotal"]?)
      installed = 0_u64 unless complete && installed >= usable
      Memory.new(usable, kilobytes(values["MemAvailable"]?), kilobytes(values["SwapTotal"]?), installed, modules)
    end

    def graphics(files : LinuxFiles) : Array(GraphicsCard)
      ids = pci_names(files)
      amd_models = amdgpu_names(files)
      files.children("/sys/bus/pci/devices").compact_map do |address|
        base = "/sys/bus/pci/devices/#{address}"
        next unless files.read("#{base}/class").starts_with?("0x03")
        vendor = files.read("#{base}/vendor").downcase.sub(/^0x/, "")
        device = files.read("#{base}/device").downcase.sub(/^0x/, "")
        revision = files.read("#{base}/revision").downcase.sub(/^0x/, "")
        subvendor = files.read("#{base}/subsystem_vendor").downcase.sub(/^0x/, "")
        subdevice = files.read("#{base}/subsystem_device").downcase.sub(/^0x/, "")
        subsystem = subvendor.empty? || subdevice.empty? ? "" : "#{subvendor}:#{subdevice}"
        model_group = ids.devices["#{vendor}:#{device}"]? || "PCI #{vendor}:#{device}"
        board_model = ids.subsystems["#{vendor}:#{device}:#{subsystem}"]? || ""
        model = files.read("#{base}/product_name")
        source = model.empty? ? GraphicsModelSource::Unknown : GraphicsModelSource::Driver
        if model.empty? && vendor == "1002" && (amd_model = amd_models["#{device}:#{revision}"]?)
          model = amd_model
          source = GraphicsModelSource::AmdDatabase
        end
        name = model.empty? ? (board_model.empty? ? model_group : board_model) : model
        GraphicsCard.new(name, vendor, device, files.link_name("#{base}/driver"), address,
          files.read("#{base}/mem_info_vram_total").to_u64? || 0_u64,
          model: model, vendor: ids.vendors[vendor]? || "", board_vendor: ids.vendors[subvendor]? || "",
          board_model: board_model, model_group: model_group, subsystem_id: subsystem,
          revision: revision, model_source: source,
          clock_mhz: active_graphics_clock(files.read("#{base}/pp_dpm_sclk")),
          memory_clock_mhz: active_graphics_clock(files.read("#{base}/pp_dpm_mclk")))
      end
    end

    def active_graphics_clock(text : String) : UInt64
      text.lines.find(&.includes?('*')).try(&.match(/\b(\d+)\s*MHz\s*\*/i)).try(&.[1].to_u64?) || 0_u64
    end

    def common_memory_model(memory : Memory) : String
      modules = memory.modules
      return "" if memory.installed == 0 || modules.empty? || modules.sum(&.bytes.to_u128) != memory.installed
      first = modules.first
      return "" if first.manufacturer.empty? || first.part_number.empty?
      return "" unless modules.all? { |mod| mod.manufacturer.downcase == first.manufacturer.downcase && mod.part_number.upcase == first.part_number.upcase }
      [[first.manufacturer, first.series].reject(&.empty?).join(" "), first.part_number].join(" · ")
    end

    # PCI device names can describe a whole GPU family. Subsystem names identify
    # the board separately; neither is assumed to be a verified GPU model.
    def pci_names(files : LinuxFiles) : PciNames
      vendors = files.children("/sys/bus/pci/devices").compact_map do |address|
        base = "/sys/bus/pci/devices/#{address}"
        files.read("#{base}/vendor").sub(/^0x/, "") if files.read("#{base}/class").starts_with?("0x03")
      end.to_set
      vendor_names = {} of String => String
      device_names = {} of String => String
      subsystem_names = {} of String => String
      text = ""
      paths = ["/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids", "/app/share/hwdata/pci.ids"]
      if appdir = ENV["APPDIR"]?
        paths << "#{appdir}/usr/share/hwdata/pci.ids"
      end
      paths.each do |path|
        text = files.read(path)
        break unless text.empty?
      end
      vendor = ""
      device = ""
      vendor_name = ""
      text.each_line do |line|
        if match = line.match(/^([0-9a-f]{4})\s+(.+)$/)
          vendor, vendor_name = match[1], match[2]
          vendor_names[vendor] = vendor_name
          device = ""
        elsif vendors.includes?(vendor) && (match = line.match(/^\t([0-9a-f]{4})\s+(.+)$/))
          device = match[1]
          device_names["#{vendor}:#{device}"] = "#{vendor_name} #{match[2]}"
        elsif vendors.includes?(vendor) && !device.empty? && (match = line.match(/^\t\t([0-9a-f]{4}) ([0-9a-f]{4})\s+(.+)$/))
          subsystem_names["#{vendor}:#{device}:#{match[1]}:#{match[2]}"] = match[3]
        end
      end
      PciNames.new(vendor_names, device_names, subsystem_names)
    end

    # libdrm distinguishes AMD variants sharing the same PCI device ID by their
    # revision. Never infer a model from device ID or VRAM capacity alone.
    def amdgpu_names(files : LinuxFiles) : Hash(String, String)
      paths = ["/usr/share/libdrm/amdgpu.ids", "/app/share/libdrm/amdgpu.ids"]
      if appdir = ENV["APPDIR"]?
        paths << "#{appdir}/usr/share/libdrm/amdgpu.ids"
      end
      text = ""
      paths.each do |path|
        text = files.read(path)
        break unless text.empty?
      end
      names = {} of String => String
      text.each_line do |line|
        if match = line.match(/^([0-9a-fA-F]{4}),\s*([0-9a-fA-F]{2}),\s*(.+)$/)
          names["#{match[1].downcase}:#{match[2].downcase}"] = match[3].strip
        end
      end
      names
    end

    def drives(files : LinuxFiles) : Array(Drive)
      files.children("/sys/block").compact_map do |name|
        base = "/sys/block/#{name}"
        # Device-mapper, loop, RAID aggregates and RAM devices would double count
        # the physical storage. Real virtio disks remain visible in VMs.
        next if name.matches?(/^(loop|ram|zram|dm-|md|sr)/)
        next unless files.exists?("#{base}/device")
        sectors = files.read("#{base}/size").to_u64? || 0_u64
        next if sectors == 0 || sectors > UInt64::MAX // 512
        number = files.read("#{base}/dev")
        properties = number.matches?(/^\d+:\d+$/) ? udev_properties(files, "/run/udev/data/b#{number}") : {} of String => String
        model = decode_udev(properties["ID_MODEL_ENC"]? || "")
        model = (properties["ID_MODEL"]? || "").gsub('_', ' ') if model.empty?
        model = files.read("#{base}/device/model") if model.empty?
        model = files.read("#{base}/device/name") if model.empty?
        model = name if model.empty?
        connection = case properties["ID_BUS"]?
                     when "usb"  then "USB"
                     when "nvme" then "NVMe"
                     when "ata"  then properties["ID_ATA_SATA"]? == "1" ? "SATA" : "ATA"
                     when "mmc"  then "MMC"
                     else             name.starts_with?("nvme") ? "NVMe" : ""
                     end
        kind = if name.starts_with?("nvme")
                 "NVMe SSD"
               elsif files.read("#{base}/queue/rotational") == "0"
                 connection == "SATA" ? "SSD" : "SSD / Flash"
               elsif files.read("#{base}/queue/rotational") == "1"
                 "HDD"
               else
                 ""
               end
        Drive.new(name, model, drive_vendor(model, properties, files.read("#{base}/device/vendor")), sectors * 512, kind,
          files.read("#{base}/removable") == "1", connection)
      end
    end

    private def udev_properties(files : LinuxFiles, path : String) : Hash(String, String)
      properties = {} of String => String
      files.read(path).each_line do |line|
        next unless line.starts_with?("E:")
        parts = line[2..].split('=', 2)
        properties[parts[0]] = parts[1].strip if parts.size == 2
      end
      properties
    end

    private def decode_udev(value : String) : String
      value.gsub(/\\x[0-9a-fA-F]{2}/) { |encoded| String.new(Bytes[encoded[2, 2].to_u8(16)]) }.scrub.strip
    end

    def drive_vendor(model : String, properties : Hash(String, String), raw_vendor : String) : String
      # ATA inquiry vendor fields often contain a protocol name. Only recognize
      # explicit brand prefixes, never assume an arbitrary model word is a brand.
      brands = {"KINGSTON" => "Kingston", "SAMSUNG" => "Samsung", "SANDISK" => "SanDisk",
                "CRUCIAL" => "Crucial", "MICRON" => "Micron", "SEAGATE" => "Seagate",
                "TOSHIBA" => "Toshiba", "KIOXIA" => "Kioxia", "INTEL" => "Intel",
                "WDC" => "Western Digital", "WD" => "Western Digital", "SKHYNIX" => "SK hynix"}
      prefix = model.split(/[\s_]+/).first?.try(&.upcase) || ""
      if brand = brands[prefix]?
        return brand
      end
      candidates = [properties["ID_VENDOR_FROM_DATABASE"]? || "", decode_udev(properties["ID_VENDOR_ENC"]? || ""),
                    (properties["ID_VENDOR"]? || "").gsub('_', ' '), raw_vendor]
      candidates.each do |candidate|
        vendor = candidate.strip
        next if {"", "ATA", "SATA", "NVME", "SCSI", "USB", "UNKNOWN", "GENERIC"}.includes?(vendor.upcase)
        next if vendor.matches?(/^0x[0-9a-f]+$/i)
        return vendor
      end
      ""
    end

    private def kilobytes(value : String?) : UInt64
      number = value.try(&.split.first?.try(&.to_u64?)) || 0_u64
      number <= UInt64::MAX // 1024 ? number * 1024 : 0_u64
    end

    private def cached_voltage(value : String?) : Float64
      # Older udev versions round values such as 1.2 V to the integer "1".
      # Do not present those truncated values as precise module voltages.
      return 0.0 unless value && value.includes?('.')
      number = value.to_f64? || 0.0
      number.finite? && number > 0 ? number : 0.0
    end
  end

  def self.format_bytes(bytes : UInt64, binary : Bool = false) : String
    value = bytes.to_f64
    units = binary ? {"B", "KiB", "MiB", "GiB", "TiB", "PiB"} : {"B", "kB", "MB", "GB", "TB", "PB"}
    base = binary ? 1024 : 1000
    index = 0
    while value >= base && index < units.size - 1
      value /= base
      index += 1
    end
    "#{value.round(1)} #{units[index]}"
  end
end

require "./peripherals"
