module SystemView
  record Monitor, connector : String, model : String, vendor : String,
    product_id : String, width_mm : Int32, height_mm : Int32,
    preferred_mode : String, preferred_hz : Float64, modes : Array(String), active : Bool,
    vendor_code : String = "", serial : String = "", graphics_address : String = "",
    number : Int32 = 0, primary : Bool? = nil, current_mode : String = "", current_hz : Float64 = 0.0
  record AudioDevice, name : String, id : String, driver : String, codecs : Array(String)
  record AudioSession, server : String = "", output : String = "", input : String = ""
  record InputDevice, name : String, kind : String, bus : String, vendor_id : String,
    product_id : String, handlers : String
  record Sensor, id : String, chip : String, label : String, kind : String, value : Float64?
  record VideoDevice, name : String, device : String, kind : String = ""

  module Inventory
    def sensors(files : LinuxFiles) : Array(Sensor)
      files.children("/sys/class/hwmon").flat_map do |chip|
        base = "/sys/class/hwmon/#{chip}"
        chip_name = files.read("#{base}/name").presence || chip
        files.children(base).compact_map do |entry|
          match = entry.match(/\A(temp|fan)(\d+)_input\z/)
          next unless match
          kind, number = match[1], match[2]
          raw = files.read("#{base}/#{entry}").to_i64?
          value = raw ? (kind == "temp" ? raw.to_f64 / 1000 : (raw >= 0 ? raw.to_f64 : nil)) : nil
          label = files.read("#{base}/#{kind}#{number}_label")
          Sensor.new("#{chip}/#{kind}#{number}", chip_name, label, kind, value)
        end
      end
    end

    def video_devices(files : LinuxFiles) : Array(VideoDevice)
      files.children("/sys/class/video4linux").compact_map do |entry|
        next unless entry.matches?(/\Avideo\d+\z/)
        base = "/sys/class/video4linux/#{entry}"
        number = files.read("#{base}/dev")
        properties = number.matches?(/\A\d+:\d+\z/) ? udev_properties(files, "/run/udev/data/c#{number}") : {} of String => String
        capabilities = properties["ID_V4L_CAPABILITIES"]? || ""
        next if !capabilities.empty? && !capabilities.split(':').includes?("capture")
        name = files.read("#{base}/name").presence || properties["ID_V4L_PRODUCT"]? || entry
        VideoDevice.new(name, "/dev/#{entry}", capabilities.split(':').includes?("capture") ? "capture" : "")
      end
    end

    def monitors(files : LinuxFiles) : Array(Monitor)
      files.children("/sys/class/drm").compact_map do |entry|
        next unless match = entry.match(/^card\d+-(.+)$/)
        base = "/sys/class/drm/#{entry}"
        next unless files.read("#{base}/status") == "connected"
        card = entry.split('-', 2).first
        monitor_from_edid(match[1], files.read_bytes("#{base}/edid"),
          files.read("#{base}/modes").lines.reject(&.empty?).uniq, files.read("#{base}/enabled") == "enabled")
          .copy_with(graphics_address: files.link_name("/sys/class/drm/#{card}/device"))
      end
    end

    def monitor_from_edid(connector : String, data : Bytes, modes : Array(String), active : Bool) : Monitor
      valid = data.size >= 128 && data[0, 8] == Bytes[0, 255, 255, 255, 255, 255, 255, 0] && data[0, 128].sum(0) { |byte| byte.to_i } % 256 == 0
      model, vendor, product, vendor_code, serial = "", "", "", "", ""
      width, height = 0, 0
      preferred, hz = "", 0.0
      if valid
        code = (data[8].to_i << 8) | data[9].to_i
        vendor = String.build { |text| {10, 5, 0}.each { |shift| text << (((code >> shift) & 31) + 64).chr } }
        vendor = "" unless vendor.matches?(/\A[A-Z]{3}\z/)
        vendor_code = vendor
        vendors = {"DEL" => "Dell", "SAM" => "Samsung", "GSM" => "LG", "ACI" => "ASUS", "AUS" => "ASUS",
                   "ACR" => "Acer", "BNQ" => "BenQ", "PHL" => "Philips", "HWP" => "HP", "LEN" => "Lenovo",
                   "MSI" => "MSI", "IVM" => "iiyama", "EIZ" => "EIZO", "VSC" => "ViewSonic"}
        vendor = vendors[vendor]? || vendor
        product = (data[10].to_i | (data[11].to_i << 8)).to_s(16).rjust(4, '0')
        width, height = data[21].to_i * 10, data[22].to_i * 10
        {54, 72, 90, 108}.each do |offset|
          if data[offset] == 0 && data[offset + 1] == 0 && data[offset + 3] == 0xfc
            model = String.new(data[offset + 5, 13]).scrub.delete('\0').strip
          elsif data[offset] == 0 && data[offset + 1] == 0 && data[offset + 3] == 0xff
            serial = String.new(data[offset + 5, 13]).scrub.delete('\0').strip
          end
        end
        clock = (data[54].to_i | (data[55].to_i << 8)) * 10_000
        if clock > 0
          x = data[56].to_i | ((data[58].to_i & 0xf0) << 4)
          y = data[59].to_i | ((data[61].to_i & 0xf0) << 4)
          blank_x = data[57].to_i | ((data[58].to_i & 0x0f) << 8)
          blank_y = data[60].to_i | ((data[61].to_i & 0x0f) << 8)
          if x > 0 && y > 0
            preferred = "#{x} × #{y}"
            hz = clock.to_f64 / ((x + blank_x) * (y + blank_y))
            hz *= 2 if (data[71] & 0x80) != 0
          end
        end
      end
      Monitor.new(connector, model, vendor, product, width, height, preferred, hz, modes, active,
        vendor_code: vendor_code, serial: serial)
    end

    def audio_devices(files : LinuxFiles) : Array(AudioDevice)
      files.read("/proc/asound/cards").lines.compact_map do |line|
        next unless match = line.match(/^\s*(\d+)\s+\[([^\]]+)\]:\s*(.+?)\s+-\s+(.+)$/)
        number = match[1]
        codecs = files.children("/proc/asound/card#{number}").select { |name| name.starts_with?("codec#") }.compact_map do |name|
          files.read("/proc/asound/card#{number}/#{name}").lines.find(&.starts_with?("Codec: ")).try(&.lchop("Codec: "))
        end
        AudioDevice.new(match[4].strip, match[2].strip, match[3].strip, codecs.uniq)
      end
    end

    def input_devices(files : LinuxFiles) : Array(InputDevice)
      blocks = files.read("/proc/bus/input/devices").split(/\n\s*\n/)
      keyboard_interfaces = blocks.compact_map do |block|
        handlers = block.match(/^H: Handlers=([^\n]*)$/m).try(&.[1]).to_s.split
        next unless handlers.includes?("kbd")
        name = block.match(/^N: Name="([^\n]*)"$/m).try(&.[1]) || ""
        physical = block.match(/^P: Phys=([^\n]*)$/m).try(&.[1]).to_s.strip
        ids = block.match(/^I: Bus=([0-9a-f]+) Vendor=([0-9a-f]+) Product=([0-9a-f]+)/m)
        next if name.empty? || physical.empty? || ids.nil?
        {name, physical, ids[1], ids[2], ids[3]}
      end
      blocks.compact_map do |block|
        name = block.match(/^N: Name="([^\n]*)"$/m).try(&.[1]) || ""
        handlers = block.match(/^H: Handlers=([^\n]*)$/m).try(&.[1]) || ""
        event = handlers.split.find { |handler| handler.matches?(/^event\d+$/) }
        next unless event
        number = files.read("/sys/class/input/#{event}/dev")
        properties = number.matches?(/^\d+:\d+$/) ? udev_properties(files, "/run/udev/data/c#{number}") : {} of String => String
        kinds = {"ID_INPUT_JOYSTICK" => "gamepad", "ID_INPUT_TOUCHPAD" => "touchpad", "ID_INPUT_TOUCHSCREEN" => "touchscreen",
                 "ID_INPUT_TABLET" => "tablet", "ID_INPUT_KEYBOARD" => "keyboard", "ID_INPUT_MOUSE" => "mouse"}
        kind = kinds.find { |key, _value| properties[key]? == "1" }.try(&.[1]) || ""
        kind = "gamepad" if kind.empty? && handlers.split.any?(&.starts_with?("js"))
        kind = "mouse" if kind.empty? && handlers.split.any?(&.starts_with?("mouse"))
        next if kind.empty? || name.empty?
        ids = block.match(/^I: Bus=([0-9a-f]+) Vendor=([0-9a-f]+) Product=([0-9a-f]+)/m)
        physical = block.match(/^P: Phys=([^\n]*)$/m).try(&.[1]).to_s.strip
        if kind == "mouse" && ids && !physical.empty? && name.ends_with?(" Mouse")
          identity = {name.rchop(" Mouse"), physical, ids[1], ids[2], ids[3]}
          next if keyboard_interfaces.includes?(identity)
        end
        bus = case ids.try(&.[1])
              when "0003" then "USB"
              when "0005" then "Bluetooth"
              when "0011" then "PS/2"
              else             ""
              end
        InputDevice.new(name, kind, bus, ids.try(&.[2]) || "", ids.try(&.[3]) || "", handlers.strip)
      end
    end
  end
end
