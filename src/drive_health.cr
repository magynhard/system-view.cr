require "./inventory"

module SystemView::DriveHealthDiscovery
  extend self

  SERVICE = "org.freedesktop.UDisks2"
  ROOT    = "/org/freedesktop/UDisks2"

  # Read only the daemon's cached properties: never open devices or trigger an
  # update, which could wake a sleeping disk or require authorization.
  def scan(drives : Array(SystemView::Drive), bus : SystemView::NetworkBus) : Array(SystemView::Drive)
    drives.map do |drive|
      block = bus.properties(SERVICE, "#{ROOT}/block_devices/#{drive.name}", "#{SERVICE}.Block")
      path = block.try(&.["Drive"]).try(&.string) || ""
      next drive if path.empty? || path == "/"
      ata = bus.properties(SERVICE, path, "#{SERVICE}.Drive.Ata")
      nvme = ata ? nil : bus.properties(SERVICE, path, "#{SERVICE}.NVMe.Controller")
      drive.copy_with(health: parse(ata, nvme))
    end
  end

  def parse(ata : SystemView::NetworkValue?, nvme : SystemView::NetworkValue?) : SystemView::DriveHealth
    if ata
      return SystemView::DriveHealth.new unless ata["SmartSupported"].try(&.boolean) == true && ata["SmartEnabled"].try(&.boolean) == true && uint64(ata["SmartUpdated"]) > 0
      temperature = real(ata["SmartTemperature"])
      seconds = uint64(ata["SmartPowerOnSeconds"])
      return SystemView::DriveHealth.new(failing: ata["SmartFailing"].try(&.boolean),
        temperature: temperature > 0 && temperature.finite? ? temperature - 273.15 : nil,
        power_on_hours: seconds > 0 ? seconds // 3600 : nil, updated_at: uint64(ata["SmartUpdated"]))
    end
    if nvme && uint64(nvme["SmartUpdated"]) > 0
      warning = nvme["SmartCriticalWarning"]
      temp = nvme["SmartTemperature"].try(&.raw_variant)
      kelvin = temp && temp.type_string == "q" ? LibGLib.g_variant_get_uint16(temp).to_f64 : 0.0
      hours = uint64(nvme["SmartPowerOnHours"])
      return SystemView::DriveHealth.new(failing: warning && warning.raw_variant.type_string == "as" ? !warning.children.empty? : nil,
        temperature: kelvin > 0 ? kelvin - 273.15 : nil, power_on_hours: hours > 0 ? hours : nil,
        updated_at: uint64(nvme["SmartUpdated"]))
    end
    SystemView::DriveHealth.new
  end

  def updated_text(value : UInt64?) : String
    return "" unless value && value <= Int64::MAX
    Time.unix(value.to_i64).to_local.to_s("%Y-%m-%d %H:%M")
  rescue ArgumentError | OverflowError
    ""
  end

  private def uint64(value : SystemView::NetworkValue?) : UInt64
    variant = value.try(&.raw_variant)
    variant && variant.type_string == "t" ? LibGLib.g_variant_get_uint64(variant) : 0_u64
  end

  private def real(value : SystemView::NetworkValue?) : Float64
    variant = value.try(&.raw_variant)
    variant && variant.type_string == "d" ? LibGLib.g_variant_get_double(variant) : 0.0
  end
end
