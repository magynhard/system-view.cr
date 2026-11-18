require "./inventory"
require "./firmware"
require "./drive_health"

module SystemView
  # Clipboard export in plain English, independent of the UI locale, so copied
  # reports stay internationally readable.
  module SnapshotExport
    extend self

    def overview(data : Snapshot) : String
      lines = ["# System View — #{report_title(data)}"]
      lines << "## Summary"
      overview_section(lines, data)
      lines.join("\n")
    end

    def full(data : Snapshot, firmware : FirmwareDetails? = nil) : String
      lines = ["# System View — #{report_title(data)}"]
      lines << "## Graphics"
      graphics_section(lines, data)
      lines << "## Processor"
      processor_section(lines, data, firmware)
      lines << "## Mainboard"
      mainboard_section(lines, data)
      lines << "## Drives"
      drives_section(lines, data)
      lines << "## Memory"
      memory_section(lines, data, firmware)
      lines << "## Monitors"
      monitors_section(lines, data)
      lines << "## Audio"
      audio_section(lines, data)
      lines << "## Input Devices"
      inputs_section(lines, data)
      lines << "## Network"
      network_section(lines, data)
      lines << "## Operating System"
      system_section(lines, data)
      lines.join("\n")
    end

    private def report_title(data : Snapshot) : String
      data.hostname.presence || data.os.presence || "Unknown system"
    end

    private def add_rows(lines : Array(String), entries : Array(Tuple(String, String))) : Nil
      entries.each do |title, value|
        next if value.empty?
        parts = value.split("\n").reject(&.empty?)
        next if parts.empty?
        lines << "- **#{title}:** #{parts.shift}"
        parts.each { |line| lines << "  - #{line}" }
      end
    end

    private def unknown(value : String) : String
      value.empty? ? "Unknown" : value
    end

    private def capacity(bytes : UInt64, binary : Bool = false) : String
      bytes > 0 ? SystemView.format_bytes(bytes, binary) : "Unknown"
    end

    private def enabled(value : Bool?) : String
      value.nil? ? "Unknown" : (value ? "Yes" : "No")
    end

    private def uptime_text(seconds : Float64) : String
      return "Unknown" unless seconds > 0
      total = seconds.to_i
      days = total // 86_400
      hours = (total % 86_400) // 3_600
      minutes = (total % 3_600) // 60
      if days > 0
        "%{days} d %{hours} h %{minutes} min" % {days: days, hours: hours, minutes: minutes}
      elsif hours > 0
        "%{hours} h %{minutes} min" % {hours: hours, minutes: minutes}
      else
        "%{minutes} min" % {minutes: minutes}
      end
    end

    private def frequency(khz : UInt64) : String
      return "Unknown" if khz == 0
      khz >= 1_000_000 ? "#{(khz / 1_000_000.0).round(2)} GHz" : "#{(khz / 1000.0).round(1)} MHz"
    end

    private def link_speed(mbps : Float64) : String
      return "Unknown" unless mbps > 0
      mbps >= 1000 ? "#{(mbps / 1000).round(2)} Gbit/s" : "#{mbps.round(1)} Mbit/s"
    end

    private def network_kind(kind : String) : String
      case kind
      when "wifi"      then "Wi-Fi"
      when "bluetooth" then "Bluetooth PAN"
      else                  "Ethernet (LAN)"
      end
    end

    private def network_state(state : String) : String
      case state
      when "connected"     then "Connected"
      when "disconnected"  then "Disconnected"
      when "connecting"    then "Connecting"
      when "disconnecting" then "Disconnecting"
      when "unavailable"   then "Unavailable"
      when "unmanaged"     then "Unmanaged"
      when "failed"        then "Connection failed"
      else                      "Unknown"
      end
    end

    private def address_method(method : String) : String
      case method
      when "auto"       then "Automatic"
      when "manual"     then "Manual"
      when "dhcp"       then "DHCP"
      when "link-local" then "Link-local"
      when "shared"     then "Shared"
      when "disabled"   then "Disabled"
      when "ignore"     then "Ignored"
      else                   "Unknown"
      end
    end

    private def input_kind(kind : String) : String
      case kind
      when "keyboard"    then "Keyboard"
      when "mouse"       then "Mouse"
      when "gamepad"     then "Gamepad / Joystick"
      when "touchpad"    then "Touchpad"
      when "touchscreen" then "Touchscreen"
      when "tablet"      then "Graphics tablet"
      else                    "Input device"
      end
    end

    private def overview_section(lines : Array(String), data : Snapshot) : Nil
      hardware = [] of Tuple(String, String)
      cpu = data.processor
      cpu_info = [cpu.name, "%{cores} cores · %{threads} threads" % {cores:   cpu.cores > 0 ? cpu.cores.to_s : "Unknown",
                                                                     threads: cpu.threads > 0 ? cpu.threads.to_s : "Unknown"}].reject(&.empty?).join("\n")
      hardware << {"Processor", cpu_info}
      hardware << {"Mainboard", [data.mainboard.vendor, data.mainboard.name].reject(&.empty?).join(" ")}
      graphics = data.graphics.map do |gpu|
        vendor = gpu.board_vendor.empty? ? gpu.vendor : gpu.board_vendor
        vendor = "ASUS" if vendor.starts_with?("ASUSTeK")
        [vendor.empty? ? "Unknown" : vendor, gpu.name, capacity(gpu.memory, binary: true)].join(" · ")
      end
      hardware << {"Graphics", graphics.join("\n")} unless graphics.empty?
      monitors = data.monitors.map do |monitor|
        [monitor.vendor, monitor.model, monitor.preferred_mode, monitor.connector].map { |value| unknown(value) }.join(" · ")
      end
      hardware << {"Monitors", monitors.join("\n")} unless monitors.empty?
      memory_info = [common_memory_model(data.memory), capacity(data.memory.installed, binary: true)].reject(&.empty?)
      kinds = data.memory.modules.map(&.kind).reject(&.empty?).uniq
      memory_info << kinds.join(" / ") unless kinds.empty?
      hardware << {"Memory", memory_info.join(" · ")}
      storage = data.drives.map { |drive| "#{drive.model} · #{capacity(drive.bytes)}" }
      hardware << {"Storage", storage.join("\n")} unless storage.empty?
      connections = data.connectivity.devices.map do |device|
        lan_ip = device.kind == "ethernet" ? device.ipv4.addresses.first?.try(&.split('/').first) || "" : ""
        [network_kind(device.kind), device.interface, network_state(device.state),
         device.ssid, device.speed_mbps > 0 ? link_speed(device.speed_mbps) : "", lan_ip].reject(&.empty?).join(" · ")
      end
      data.connectivity.bluetooth.each do |adapter|
        connections << ["Bluetooth", adapter.name.presence || adapter.id,
                        adapter.powered.nil? ? "Unknown" : (adapter.powered ? "Active" : "Inactive")].join(" · ")
      end
      hardware << {"Network", connections.empty? ? "None" : connections.join("\n")}
      lines << "### Hardware summary"
      add_rows(lines, hardware)
      lines << "### System"
      add_rows(lines, [{"Operating System", data.os}, {"Kernel", data.kernel},
                       {"Desktop Environment", data.desktop}, {"Uptime", uptime_text(data.uptime)}])
    end

    private def common_memory_model(memory : Memory) : String
      modules = memory.modules
      return "" if memory.installed == 0 || modules.empty? || modules.sum(&.bytes.to_u128) != memory.installed
      first = modules.first
      return "" if first.manufacturer.empty? || first.part_number.empty?
      return "" unless modules.all? { |mod| mod.manufacturer.downcase == first.manufacturer.downcase && mod.part_number.upcase == first.part_number.upcase }
      [[first.manufacturer, first.series].reject(&.empty?).join(" "), first.part_number].join(" · ")
    end

    private def graphics_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Display controller:** Unknown" if data.graphics.empty?
      data.graphics.each do |gpu|
        lines << "### #{gpu.name}"
        lines << "#### Identification"
        add_rows(lines, [{"GPU model", gpu.model}, {"GPU manufacturer", gpu.vendor},
                         {"Card manufacturer", gpu.board_vendor}, {"Board model", gpu.board_model},
                         {"Model group", gpu.model_group}])
        attached = data.monitors.select { |monitor| monitor.graphics_address == gpu.address }
        unless attached.empty?
          displays = attached.map do |monitor|
            [monitor_title(monitor), monitor.connector, monitor.current_mode,
             monitor.current_hz > 0 ? "#{monitor.current_hz.round(2)} Hz" : ""].reject(&.empty?).join(" · ")
          end
          add_rows(lines, [{"Connected monitors", displays.join("\n")}])
        end
        lines << "#### PCI and driver"
        add_rows(lines, [{"PCI ID", "#{gpu.vendor_id}:#{gpu.device_id}"},
                         {"Subsystem ID", gpu.subsystem_id}, {"Revision", gpu.revision},
                         {"PCI address", gpu.address}, {"Kernel driver", gpu.driver}])
        lines << "#### Memory and clocks"
        add_rows(lines, [{"Dedicated video memory", capacity(gpu.memory, binary: true)},
                         {"Current GPU clock", gpu.clock_mhz > 0 ? "#{gpu.clock_mhz} MHz" : "Not reported"},
                         {"Current video memory clock", gpu.memory_clock_mhz > 0 ? "#{gpu.memory_clock_mhz} MHz" : "Not reported"}])
        lines << "#### Graphics APIs"
        add_rows(lines, [{"OpenGL", gpu.opengl.empty? ? "Not reported" : gpu.opengl},
                         {"GLSL", gpu.glsl.empty? ? "Not reported" : gpu.glsl},
                         {"OpenGL ES", gpu.opengl_es.empty? ? "Not reported" : gpu.opengl_es},
                         {"OpenGL renderer", gpu.renderer},
                         {"Vulkan", gpu.vulkan.empty? ? "Not reported" : gpu.vulkan},
                         {"Vulkan driver", gpu.vulkan_driver}])
      end
    end

    private def processor_section(lines : Array(String), data : Snapshot, firmware : FirmwareDetails?) : Nil
      cpu = data.processor
      lines << "### Identification"
      add_rows(lines, [{"Model", cpu.name}, {"Manufacturer", cpu.vendor},
                       {"Architecture", cpu.architecture}, {"CPU family", cpu.family},
                       {"Model ID", cpu.model_id}, {"Stepping", cpu.stepping}])
      lines << "### Topology and socket"
      add_rows(lines, [{"Physical cores", cpu.cores > 0 ? cpu.cores.to_s : "Unknown"},
                       {"Logical processors", cpu.threads > 0 ? cpu.threads.to_s : "Unknown"},
                       {"Socket count", cpu.sockets > 0 ? cpu.sockets.to_s : "Unknown"}])
      if firmware
        firmware.processors.each_with_index do |entry, index|
          lines << "### Socket #{index + 1}" if firmware.processors.size > 1
          add_rows(lines, [{"Socket", entry.socket}, {"Socket type", entry.upgrade}])
        end
      end
      lines << "### Clock speed"
      speed = cpu.clocks
      current = frequency(speed.current_min_khz)
      current += " – #{frequency(speed.current_max_khz)}" if speed.current_max_khz > speed.current_min_khz
      add_rows(lines, [{"Base clock", frequency(speed.base_khz)},
                       {"Minimum clock", frequency(speed.minimum_khz)},
                       {"Maximum clock", frequency(speed.maximum_khz)},
                       {"Current clock range", current}])
      lines << "### Clock control"
      add_rows(lines, [{"Available frequency steps", speed.steps_khz.map { |khz| frequency(khz) }.join(" · ")},
                       {"Frequency driver", speed.driver}, {"Governor", speed.governor},
                       {"Boost enabled", speed.boost.nil? ? "Unknown" : (speed.boost ? "Yes" : "No")}])
      if firmware
        firmware.processors.each_with_index do |entry, index|
          suffix = firmware.processors.size > 1 ? " · Socket #{index + 1}" : ""
          lines << "### Additional processor information#{suffix}"
          add_rows(lines, [{"Voltage", entry.voltage}, {"External clock", entry.external_clock},
                           {"Configured clock", entry.configured_clock}, {"Maximum clock", entry.maximum_clock}])
        end
      end
      lines << "### Caches"
      cpu.caches.each do |cache|
        kind = case cache.kind
               when "Data"        then "Data"
               when "Instruction" then "Instructions"
               when "Unified"     then "Data and instructions"
               else                    cache.kind
               end
        total = cache.bytes <= UInt64::MAX // cache.instances ? capacity(cache.bytes * cache.instances, binary: true) : "Unknown"
        info = ["%{count} × %{size} · %{total} total" % {count: cache.instances,
                                                         size: capacity(cache.bytes, binary: true), total: total}]
        info << "%{size} cache lines" % {size: capacity(cache.line_bytes, binary: true)} if cache.line_bytes > 0
        info << "%{ways}-way associative" % {ways: cache.ways} if cache.ways > 0
        add_rows(lines, [{"L#{cache.level} cache (#{kind})", info.join("\n")}])
      end
      if firmware
        firmware.processors.each_with_index do |entry, index|
          suffix = firmware.processors.size > 1 ? " · Socket #{index + 1}" : ""
          lines << "### Processor features#{suffix}"
          add_rows(lines, [{"Processor Features", entry.capabilities.join("\n")},
                           {"Characteristics", entry.characteristics.join("\n")}])
        end
      end
    end

    private def mainboard_section(lines : Array(String), data : Snapshot) : Nil
      board = data.mainboard
      lines << "### Identification"
      add_rows(lines, [{"Manufacturer", board.vendor}, {"Model", board.name}, {"Revision", board.version}])
      lines << "### Firmware"
      add_rows(lines, [{"BIOS vendor", board.bios_vendor}, {"BIOS version", board.bios_version},
                       {"BIOS date", board.bios_date}])
      lines << "### Boot and security"
      mode = case board.boot_mode
             when "uefi"   then "UEFI"
             when "legacy" then "Legacy BIOS"
             else               "Unknown"
             end
      secure_boot = board.secure_boot.nil? ? "Unknown" : (board.secure_boot ? "Active" : "Inactive")
      tpm = if board.tpm_present.nil?
              "Unknown"
            elsif !board.tpm_present
              "Not detected"
            elsif board.tpm_versions.empty?
              "Detected"
            else
              board.tpm_versions.map { |version| "TPM #{version}" }.join(" · ")
            end
      add_rows(lines, [{"Boot mode", mode}, {"Secure Boot", secure_boot}, {"TPM", tpm}])
    end

    private def drives_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Drives:** Unknown" if data.drives.empty?
      data.drives.each do |drive|
        lines << "### #{drive.model}"
        add_rows(lines, [{"Model", drive.model}, {"Manufacturer", drive.vendor},
                         {"Capacity", capacity(drive.bytes)}, {"Type", drive.kind},
                         {"Connection", drive.connection}, {"Device", "/dev/#{drive.name}"},
                         {"Removable", drive.removable ? "Yes" : "No"},
                         {"Status (SMART)", drive.health.failing.nil? ? "Not reported" : (drive.health.failing ? "Warning" : "OK")},
                         {"Temperature", drive.health.temperature.try { |value| "#{value.round(1)} °C" } || "Not reported"},
                         {"Power-on hours", drive.health.power_on_hours.try(&.to_s) || "Not reported"},
                         {"Last updated", DriveHealthDiscovery.updated_text(drive.health.updated_at).presence || "Not reported"}])
      end
    end

    private def memory_section(lines : Array(String), data : Snapshot, firmware : FirmwareDetails?) : Nil
      memory = data.memory
      lines << "### Memory"
      add_rows(lines, [{"Installed RAM", capacity(memory.installed, binary: true)},
                       {"Usable RAM", capacity(memory.total, binary: true)},
                       {"Available RAM", capacity(memory.available, binary: true)},
                       {"Swap", memory.swap == 0 ? "None" : capacity(memory.swap, binary: true)}])
      memory.modules.each_with_index do |mod, index|
        title = mod.slot.empty? ? "Module #{index + 1}" : mod.slot
        lines << "### #{title}"
        info = [capacity(mod.bytes, binary: true)]
        info << mod.kind unless mod.kind.empty?
        info << "#{mod.speed_mts} MT/s" if mod.speed_mts > 0
        voltage = mod.voltage > 0 && mod.voltage.finite? ? "#{mod.voltage} V" : ""
        minimum = mod.minimum_voltage > 0 && mod.minimum_voltage.finite? ? "#{mod.minimum_voltage} V" : ""
        maximum = mod.maximum_voltage > 0 && mod.maximum_voltage.finite? ? "#{mod.maximum_voltage} V" : ""
        part = mod.part_number
        manufacturer = mod.manufacturer
        if firmware
          matching = firmware.memory.select { |entry| [entry.bank, entry.slot].reject(&.empty?).join(" · ") == mod.slot }
          if matching.size == 1
            voltage = matching.first.voltage unless matching.first.voltage.empty?
            minimum = matching.first.minimum_voltage unless matching.first.minimum_voltage.empty?
            maximum = matching.first.maximum_voltage unless matching.first.maximum_voltage.empty?
            part = matching.first.part_number unless matching.first.part_number.empty?
            manufacturer = matching.first.manufacturer unless matching.first.manufacturer.empty?
          end
        end
        identity = RamIdentifiers.identify(part, manufacturer)
        brand = [identity.manufacturer, identity.series].reject(&.empty?).join(" ")
        model = [brand, part].reject(&.empty?).join(" · ")
        add_rows(lines, [{"Model", [model, info.join(" · ")].reject(&.empty?).join("\n")},
                         {"Timings (CL–tRCD–tRP–tRAS)", "Not reported"},
                         {"Voltage", voltage}, {"Minimum voltage", minimum}, {"Maximum voltage", maximum}])
      end
    end

    private def monitors_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Monitor:** Unknown" if data.monitors.empty?
      data.monitors.each_with_index do |monitor, index|
        lines << "### #{monitor_title(monitor, index + 1)}"
        rows = [{"Manufacturer", monitor.vendor}, {"Model", monitor.model},
                {"Product ID", monitor.product_id}, {"Connection", monitor.connector},
                {"Active", monitor.active ? "Yes" : "No"},
                {"Current resolution", monitor.current_mode.empty? ? "Not reported" : monitor.current_mode},
                {"Current refresh rate", monitor.current_hz > 0 ? "#{monitor.current_hz.round(2)} Hz" : "Not reported"},
                {"Preferred resolution", monitor.preferred_mode},
                {"Preferred refresh rate", monitor.preferred_hz > 0 ? "#{monitor.preferred_hz.round(2)} Hz" : ""}]
        if monitor.width_mm > 0 && monitor.height_mm > 0
          diagonal = Math.sqrt(monitor.width_mm.to_f64 ** 2 + monitor.height_mm.to_f64 ** 2) / 25.4
          rows << {"Display size", "#{monitor.width_mm} × #{monitor.height_mm} mm"}
          rows << {"Diagonal", "#{diagonal.round(1)}″"}
        end
        rows << {"Supported resolutions", monitor.modes.join(" · ")} unless monitor.modes.empty?
        add_rows(lines, rows)
      end
    end

    private def monitor_title(monitor : Monitor, fallback : Int32 = 1) : String
      title = "Monitor #{monitor.number > 0 ? monitor.number : fallback}"
      monitor.primary == true ? "#{title} (Primary)" : title
    end

    private def audio_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Audio device:** Unknown" if data.audio.empty?
      data.audio.each do |device|
        lines << "### #{device.name}"
        add_rows(lines, [{"Name", device.name}, {"Device ID", device.id},
                         {"Driver", device.driver}, {"Codecs", device.codecs.join("\n")}])
      end
    end

    private def inputs_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Input device:** Unknown" if data.inputs.empty?
      data.inputs.each do |device|
        lines << "### #{device.name}"
        add_rows(lines, [{"Type", input_kind(device.kind)}, {"Connection", device.bus},
                         {"Vendor ID", device.vendor_id}, {"Product ID", device.product_id}])
      end
    end

    private def network_section(lines : Array(String), data : Snapshot) : Nil
      lines << "- **Network adapters:** None" if data.connectivity.devices.empty? && data.connectivity.bluetooth.empty?
      data.connectivity.devices.each do |device|
        lines << "### #{network_kind(device.kind)} · #{device.interface}"
        rows = [] of Tuple(String, String)
        rows << {"Model", device.name} unless device.name.empty?
        rows << {"Interface", device.interface}
        rows << {"Status", network_state(device.state)}
        rows << {"Connection profile", device.connection} unless device.connection.empty?
        rows << {"Link speed", link_speed(device.speed_mbps)}
        unless device.duplex.empty? || device.duplex == "unknown"
          rows << {"Duplex", device.duplex == "full" ? "Full duplex" : (device.duplex == "half" ? "Half duplex" : device.duplex)}
        end
        rows << {"MAC address", device.mac}
        rows << {"Permanent MAC address", device.permanent_mac} unless device.permanent_mac.empty?
        rows << {"MTU", device.mtu > 0 ? "#{device.mtu} B" : ""}
        rows << {"Kernel driver", device.driver}
        if device.kind == "wifi"
          rows << {"SSID", device.ssid}
          rows << {"Access point (BSSID)", device.bssid}
          rows << {"Signal strength", device.signal.try { |signal| "#{signal}%" } || ""}
          rows << {"Frequency", device.frequency_mhz > 0 ? "#{device.frequency_mhz} MHz" : ""}
          rows << {"Security", device.security == "open" ? "Open network" : device.security}
        end
        add_rows(lines, rows)
        network_addresses(lines, device.interface, device.ipv4, 4)
        network_addresses(lines, device.interface, device.ipv6, 6)
      end
      data.connectivity.bluetooth.each do |adapter|
        lines << "### Bluetooth · #{adapter.id}"
        add_rows(lines, [{"Name", adapter.name}, {"MAC address", adapter.address},
                         {"Enabled", enabled(adapter.powered)}, {"Bluetooth version", adapter.version},
                         {"Link speed", "Not reported"}, {"Discoverable", enabled(adapter.discoverable)},
                         {"Pairable", enabled(adapter.pairable)},
                         {"Kernel driver", adapter.driver}] + [{"Connected devices", adapter.devices.count(&.connected).to_s}])
        adapter.devices.each do |device|
          lines << "### Bluetooth · #{device.name.presence || device.address}"
          device_rows = [{"MAC address", device.address},
                         {"Connected", enabled(device.connected)}, {"Paired", enabled(device.paired)}]
          device_rows << {"Signal strength", "#{device.rssi} dBm"} if device.connected && device.rssi
          add_rows(lines, device_rows)
        end
      end
    end

    private def network_addresses(lines : Array(String), interface : String, config : NetworkAddress, version : Int32) : Nil
      lines << "### #{interface} · IPv#{version}"
      missing = config.available ? "None" : "Unknown"
      add_rows(lines, [{"IP addresses", config.addresses.empty? ? missing : config.addresses.join("\n")},
                       {"Address configuration", address_method(config.method)},
                       {"DHCP", enabled(config.dhcp)},
                       {"Gateway", config.gateway.empty? ? missing : config.gateway},
                       {"DNS servers", config.dns.empty? ? missing : config.dns.join("\n")},
                       {"Search domains", config.domains.join("\n")}])
    end

    private def system_section(lines : Array(String), data : Snapshot) : Nil
      lines << "### System"
      add_rows(lines, [{"Operating System", data.os}, {"Kernel", data.kernel},
                       {"Desktop Environment", data.desktop}, {"Hostname", data.hostname},
                       {"Uptime", uptime_text(data.uptime)}])
    end
  end
end
