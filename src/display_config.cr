require "./network"

module SystemView::DisplayConfig
  extend self
  record DesktopMonitor, connector : String, vendor : String, model : String, serial : String,
    number : Int32, primary : Bool, active : Bool, mode : String, hz : Float64
  CURRENT_STATE_TYPE = "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"

  def query : GLib::Variant?
    return nil unless ENV["DBUS_SESSION_BUS_ADDRESS"]?
    Gio.bus_get_sync(:session, nil).call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
      "org.gnome.Mutter.DisplayConfig", "GetCurrentState", nil, nil, :no_auto_start, 500, nil)
  rescue GLib::Error
    nil
  end

  def parse(reply : GLib::Variant) : Array(DesktopMonitor)
    return [] of DesktopMonitor unless reply.type_string == CURRENT_STATE_TYPE
    parts = NetworkValue.new(reply).children
    return [] of DesktopMonitor unless parts.size == 4
    primary = {} of Array(String) => Bool
    parts[2].children.each do |logical|
      values = logical.children
      next unless values.size == 7
      values[5].children.each { |spec| primary[spec.children.map(&.string)] = values[4].boolean == true }
    end
    # GNOME Settings numbers built-in panels first, then external displays in
    # GetCurrentState order (not left-to-right, and not DRM connector IDs).
    builtin, external = [] of NetworkValue, [] of NetworkValue
    parts[1].children.each do |physical|
      values = physical.children
      next unless values.size == 3
      if values[2]["is-builtin"].try(&.boolean) == true
        builtin.unshift(physical)
      else
        external << physical
      end
    end
    (builtin + external).map_with_index do |physical, index|
      values = physical.children
      spec = values[0].children.map(&.string)
      current = values[1].children.find do |mode|
        mode.children.last?.try(&.["is-current"]).try(&.boolean) == true
      end
      mode = current.try(&.children)
      dimensions = if mode && mode.size == 7
                     width, height = integer(mode[1]), integer(mode[2])
                     width > 0 && height > 0 ? "#{width} × #{height}" : ""
                   else
                     ""
                   end
      hz = current.try { |entry| variant_float(entry.children[3]) } || 0.0
      DesktopMonitor.new(spec[0], spec[1], spec[2], spec[3], index + 1,
        primary[spec]? || false, primary.has_key?(spec), dimensions, hz)
    end
  end

  def enrich(monitors : Array(Monitor), reply : GLib::Variant? = query) : Array(Monitor)
    desktop = reply ? parse(reply) : [] of DesktopMonitor
    result = monitors.map do |monitor|
      candidates = desktop.select do |entry|
        connector(entry.connector) == connector(monitor.connector) &&
          (monitor.vendor_code.empty? || entry.vendor.empty? || entry.vendor == monitor.vendor_code) &&
          (monitor.serial.empty? || entry.serial.empty? || monitor.serial == entry.serial)
      end
      next monitor unless candidates.size == 1
      match = candidates.first
      # Connector names can repeat across GPUs; never assign one compositor
      # output to multiple physical monitors with an ambiguous identity.
      peers = monitors.count do |other|
        connector(other.connector) == connector(match.connector) &&
          (other.serial.empty? || match.serial.empty? || other.serial == match.serial)
      end
      next monitor unless peers == 1
      monitor.copy_with(number: match.number, primary: match.primary, active: match.active,
        current_mode: match.mode, current_hz: match.hz)
    end
    used = result.map(&.number).select(&.>(0)).to_set
    result = result.map do |monitor|
      next monitor if monitor.number > 0
      number = 1
      while used.includes?(number)
        number += 1
      end
      used << number
      monitor.copy_with(number: number)
    end
    result.sort_by(&.number)
  end

  private def connector(name : String) : String
    name.sub(/^HDMI-A-/, "HDMI-")
  end

  private def integer(value : NetworkValue) : Int32
    # Mode dimensions have D-Bus type 'i', unlike network's unsigned values.
    value.raw_variant.type_string == "i" ? value.raw_variant.as_i32 : 0
  end

  private def variant_float(value : NetworkValue) : Float64
    variant = value.raw_variant
    number = variant.type_string == "d" ? variant.as_f64 : 0.0
    number.finite? && number > 0 ? number : 0.0
  end
end
