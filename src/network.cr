require "gi-crystal/gio"

module SystemView
  record NetworkAddress, addresses : Array(String) = [] of String, gateway : String = "",
    dns : Array(String) = [] of String, domains : Array(String) = [] of String,
    method : String = "", dhcp : Bool? = nil, available : Bool = false
  record NetworkDevice, interface : String, kind : String, name : String = "",
    driver : String = "", mac : String = "", permanent_mac : String = "",
    state : String = "", speed_mbps : Float64 = 0.0, mtu : UInt32 = 0_u32,
    duplex : String = "", connection : String = "",
    ipv4 : NetworkAddress = NetworkAddress.new, ipv6 : NetworkAddress = NetworkAddress.new,
    ssid : String = "", bssid : String = "", signal : Int32? = nil,
    frequency_mhz : UInt32 = 0_u32, security : String = ""
  record BluetoothDevice, name : String, address : String, connected : Bool,
    paired : Bool, rssi : Int16? = nil
  record BluetoothAdapter, id : String, name : String = "", address : String = "",
    powered : Bool? = nil, discoverable : Bool? = nil, pairable : Bool? = nil,
    version : String = "", driver : String = "", roles : Array(String) = [] of String,
    devices : Array(BluetoothDevice) = [] of BluetoothDevice
  record Connectivity, devices : Array(NetworkDevice) = [] of NetworkDevice,
    bluetooth : Array(BluetoothAdapter) = [] of BluetoothAdapter

  # gi-crystal does not yet expose GVariant containers or object paths. Keep
  # typed access here instead of parsing the human-readable D-Bus serialization.
  struct NetworkValue
    def raw_variant : GLib::Variant
      @value
    end

    def initialize(@value : GLib::Variant)
    end

    def children : Array(NetworkValue)
      return [] of NetworkValue unless @value.type_string.matches?(/^[a({]/)
      Array.new(LibGLib.g_variant_n_children(@value).to_i) do |index|
        NetworkValue.new(GLib::Variant.new(LibGLib.g_variant_get_child_value(@value, index.to_u64), :full))
      end
    end

    def [](key : String) : NetworkValue?
      return nil unless @value.type_string.starts_with?("a{")
      pointer = LibGLib.g_variant_lookup_value(@value, key, Pointer(Void).null)
      pointer.null? ? nil : NetworkValue.new(GLib::Variant.new(pointer, :full))
    end

    def string : String
      return "" unless @value.type_string.in?({"s", "o"})
      String.new(LibGLib.g_variant_get_string(@value, Pointer(UInt64).null)).scrub
    end

    def number : UInt32
      case @value.type_string
      when "u" then @value.as_u32
      when "y" then @value.as_u8.to_u32
      else          0_u32
      end
    end

    def boolean : Bool?
      @value.type_string == "b" ? @value.as_bool : nil
    end

    def signed : Int16?
      @value.type_string == "n" ? @value.as_i16 : nil
    end

    def bytes : String
      return "" unless @value.type_string == "ay"
      data = children.map(&.number.to_u8)
      String.new(data.to_unsafe, data.size).scrub.gsub(/[\x00-\x1f\x7f]/, "�")
    end
  end

  abstract class NetworkBus
    abstract def call(service : String, path : String, interface : String, method : String, parameters : GLib::Variant? = nil) : GLib::Variant?

    def properties(service : String, path : String, interface : String) : NetworkValue?
      return nil if path.empty? || path == "/"
      call(service, path, "org.freedesktop.DBus.Properties", "GetAll", GLib::Variant.parse("('#{interface}',)"))
        .try { |reply| NetworkValue.new(reply).children.first? }
    end
  end

  class SystemNetworkBus < NetworkBus
    @connection : Gio::DBusConnection?
    @deadline = Time.instant + 5.seconds

    def call(service : String, path : String, interface : String, method : String, parameters : GLib::Variant? = nil) : GLib::Variant?
      return nil if Time.instant >= @deadline
      connection = @connection ||= Gio.bus_get_sync(:system, nil)
      connection.call_sync(service, path, interface, method, parameters, nil, :no_auto_start, 400, nil)
    rescue GLib::Error
      nil
    end
  end

  module NetworkDiscovery
    extend self
    NM = "org.freedesktop.NetworkManager"

    def scan(files : LinuxFiles, bus : NetworkBus? = nil) : Connectivity
      devices = {} of String => NetworkValue
      paths = {} of String => String
      if reply = bus.try(&.call(NM, "/org/freedesktop/NetworkManager", NM, "GetDevices"))
        NetworkValue.new(reply).children.first?.try(&.children.each do |path|
          if properties = bus.try(&.properties(NM, path.string, "#{NM}.Device"))
            name = text(properties, "Interface")
            unless name.empty?
              devices[name] = properties
              paths[name] = path.string
            end
          end
        end)
      end
      interfaces = (files.children("/sys/class/net") + devices.keys).uniq.sort
      network = interfaces.compact_map do |name|
        base = "/sys/class/net/#{name}"
        next if name == "lo"
        properties = devices[name]?
        type = number(properties, "DeviceType")
        wireless = type == 2 || files.exists?("#{base}/wireless") || files.exists?("#{base}/phy80211")
        next unless wireless || type.in?({1_u32, 5_u32}) || files.exists?("#{base}/device")
        next unless type.in?({0_u32, 1_u32, 2_u32, 5_u32})
        kind = wireless ? "wifi" : (type == 5 ? "bluetooth" : "ethernet")
        details = bus.try(&.properties(NM, paths[name]? || "", "#{NM}.Device.#{wireless ? "Wireless" : "Wired"}")) if type.in?({1_u32, 2_u32})
        active = bus.try(&.properties(NM, text(properties, "ActiveConnection"), "#{NM}.Connection.Active"))
        settings = connection_settings(bus, text(active, "Connection"))
        access_point = bus.try(&.properties(NM, text(details, "ActiveAccessPoint"), "#{NM}.AccessPoint")) if wireless
        index = files.read("#{base}/ifindex")
        udev = Inventory.parse_fields(files.read("/run/udev/data/n#{index}").lines.select(&.starts_with?("E:")).map { |line| line[2..] }.join('\n'), '=')
        model = udev["ID_MODEL_FROM_DATABASE"]? || (udev["ID_MODEL"]? || "").gsub('_', ' ')
        vendor = udev["ID_VENDOR_FROM_DATABASE"]? || ""
        speed = if wireless
                  number(details, "Bitrate") / 1000.0
                else
                  (files.read("#{base}/speed").to_i64? || 0_i64).clamp(0_i64, Int64::MAX).to_f64
                end
        speed = number(details, "Speed").to_f64 if !wireless && number(details, "Speed") > 0
        state = device_state(number(properties, "State"), files.read("#{base}/operstate"), files.read("#{base}/carrier"))
        speed = 0.0 if state.in?({"disconnected", "unavailable", "failed"}) || files.read("#{base}/carrier") == "0"
        mac = text(properties, "HwAddress")
        mac = text(details, "HwAddress") if mac.empty?
        mac = files.read("#{base}/address") if mac.empty?
        NetworkDevice.new(name, kind, name: [vendor, model].reject(&.empty?).join(" "),
          driver: text(properties, "Driver").presence || files.link_name("#{base}/device/driver"),
          mac: mac, permanent_mac: text(details, "PermHwAddress"), state: state, speed_mbps: speed,
          mtu: number(properties, "Mtu") > 0 ? number(properties, "Mtu") : (files.read("#{base}/mtu").to_u32? || 0_u32),
          duplex: wireless ? "" : files.read("#{base}/duplex"), connection: text(active, "Id"),
          ipv4: ip_config(bus, properties, settings, 4), ipv6: ip_config(bus, properties, settings, 6),
          ssid: access_point.try(&.["Ssid"]).try(&.bytes) || "", bssid: text(access_point, "HwAddress"),
          signal: access_point.try(&.["Strength"]).try(&.number.to_i),
          frequency_mhz: number(access_point, "Frequency"), security: wifi_security(access_point))
      end
      Connectivity.new(network, bluetooth(files, bus))
    end

    private def connection_settings(bus : NetworkBus?, path : String) : NetworkValue?
      return nil if path.empty? || path == "/"
      bus.try(&.call(NM, path, "#{NM}.Settings.Connection", "GetSettings")).try { |reply| NetworkValue.new(reply).children.first? }
    end

    private def ip_config(bus : NetworkBus?, device : NetworkValue?, settings : NetworkValue?, version : Int32) : NetworkAddress
      properties = bus.try(&.properties(NM, text(device, "Ip#{version}Config"), "#{NM}.IP#{version}Config"))
      method = settings.try(&.["ipv#{version}"]).try(&.["method"]).try(&.string) || ""
      addresses = properties.try(&.["AddressData"]).try(&.children.compact_map do |entry|
        address = text(entry, "address")
        address.empty? ? nil : "#{address}/#{number(entry, "prefix")}"
      end) || [] of String
      dns = properties.try(&.["NameserverData"]).try(&.children.map { |entry| text(entry, "address") }.reject(&.empty?)) || [] of String
      if dns.empty? && version == 6
        dns = properties.try(&.["Nameservers"]).try(&.children.compact_map do |entry|
          bytes = entry.children.map(&.number)
          next unless bytes.size == 16
          bytes.each_slice(2).map { |pair| ((pair[0] << 8) | pair[1]).to_s(16) }.join(':')
        end) || [] of String
      end
      dhcp = if !text(device, "Dhcp#{version}Config").in?({"", "/"})
               true
             elsif method.in?({"manual", "disabled", "ignore", "link-local", "shared"})
               false
             elsif version == 4 && method == "auto"
               true
             elsif version == 6 && method == "dhcp"
               true
             end
      domains = properties.try(&.["Domains"]).try(&.children.map(&.string)) || [] of String
      domains.concat(properties.try(&.["Searches"]).try(&.children.map(&.string)) || [] of String)
      available = !properties.nil? || (!device.nil? && text(device, "Ip#{version}Config") == "/")
      NetworkAddress.new(addresses, text(properties, "Gateway"), dns.uniq, domains.uniq, method, dhcp, available)
    end

    def device_state(state : UInt32, operstate : String, carrier : String) : String
      case state
      when 100    then "connected"
      when 40..90 then "connecting"
      when 110    then "disconnecting"
      when 120    then "failed"
      when 30     then "disconnected"
      when 20     then "unavailable"
      when 10     then "unmanaged"
      else
        operstate == "up" && carrier == "1" ? "connected" : (operstate.in?({"down", "lowerlayerdown"}) || carrier == "0" ? "disconnected" : "")
      end
    end

    private def wifi_security(point : NetworkValue?) : String
      return "" unless point
      wpa = number(point, "WpaFlags")
      rsn = number(point, "RsnFlags")
      protocols = [] of String
      protocols << "WPA" if wpa > 0
      protocols << "WPA2" if rsn & 0x300 != 0
      protocols << "WPA3" if rsn & 0x2400 != 0
      protocols << "OWE" if rsn & 0x1800 != 0
      return protocols.join(" / ") unless protocols.empty?
      number(point, "Flags") & 1 == 0 ? "open" : "WEP"
    end

    private def bluetooth(files : LinuxFiles, bus : NetworkBus?) : Array(BluetoothAdapter)
      objects = bus.try(&.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")).try { |reply| NetworkValue.new(reply).children.first? }
      adapters = {} of String => NetworkValue
      remote = {} of String => Array(BluetoothDevice)
      objects.try(&.children.each do |entry|
        pair = entry.children
        next unless pair.size == 2
        path, interfaces = pair[0].string, pair[1]
        if adapter = interfaces["org.bluez.Adapter1"]
          adapters[path] = adapter
        end
        if device = interfaces["org.bluez.Device1"]
          connected = device["Connected"].try(&.boolean) == true
          paired = device["Paired"].try(&.boolean) == true
          next unless connected || paired
          adapter_path = text(device, "Adapter")
          (remote[adapter_path] ||= [] of BluetoothDevice) << BluetoothDevice.new(
            text(device, "Alias").presence || text(device, "Name"), text(device, "Address"), connected, paired, device["RSSI"].try(&.signed))
        end
      end)
      ids = (files.children("/sys/class/bluetooth").select { |name| name.matches?(/^hci\d+$/) } + adapters.keys.map { |path| File.basename(path) }).uniq.sort
      ids.map do |id|
        path = adapters.keys.find { |key| File.basename(key) == id } || ""
        properties = adapters[path]?
        version = properties.try(&.["Version"]).try(&.number)
        versions = {0 => "1.0b", 1 => "1.1", 2 => "1.2", 3 => "2.0 + EDR", 4 => "2.1 + EDR", 5 => "3.0 + HS", 6 => "4.0", 7 => "4.1", 8 => "4.2", 9 => "5.0", 10 => "5.1", 11 => "5.2", 12 => "5.3", 13 => "5.4", 14 => "6.0", 15 => "6.1", 16 => "6.2"}
        BluetoothAdapter.new(id, name: text(properties, "Alias").presence || text(properties, "Name"),
          address: text(properties, "Address").presence || files.read("/sys/class/bluetooth/#{id}/address"),
          powered: properties.try(&.["Powered"]).try(&.boolean), discoverable: properties.try(&.["Discoverable"]).try(&.boolean),
          pairable: properties.try(&.["Pairable"]).try(&.boolean), version: version.try { |code| versions[code.to_i]? } || "",
          driver: files.link_name("/sys/class/bluetooth/#{id}/device/driver"),
          roles: properties.try(&.["Roles"]).try(&.children.map(&.string)) || [] of String,
          devices: (remote[path]? || [] of BluetoothDevice).sort_by { |device| {device.connected ? 0 : 1, device.name, device.address} })
      end
    end

    private def text(value : NetworkValue?, key : String) : String
      value.try(&.[key]).try(&.string) || ""
    end

    private def number(value : NetworkValue?, key : String) : UInt32
      value.try(&.[key]).try(&.number) || 0_u32
    end
  end
end
