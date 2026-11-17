require "./subprocess_output"

module SystemView::GraphicsDiagnostics
  extend self
  alias Runner = Proc(String, Array(String), Hash(String, String), String)

  # Diagnostics are optional and never run with elevated privileges. Match
  # reported PCI IDs, and leave identical multi-GPU configurations unassigned
  # rather than attributing the default renderer to every installed card.
  def scan(cards : Array(GraphicsCard), runner : Runner = ->run(String, Array(String), Hash(String, String))) : Array(GraphicsCard)
    vulkan = parse_vulkan(runner.call("vulkaninfo", ["--summary"], {} of String => String))
    cards.map do |card|
      next card unless cards.count { |other| other.vendor_id == card.vendor_id && other.device_id == card.device_id } == 1
      prime = "pci-#{card.address.gsub(/[:.]/, "_")}"
      gl = parse_opengl(runner.call("glxinfo", ["-B"], {"DRI_PRIME" => prime}), card.vendor_id, card.device_id)
      matches = vulkan.select { |device| device["vendorID"]? == "0x#{card.vendor_id}" && device["deviceID"]? == "0x#{card.device_id}" && device["deviceType"]? != "PHYSICAL_DEVICE_TYPE_CPU" }
      vk = matches.size == 1 ? matches.first : {} of String => String
      card.copy_with(opengl: gl["OpenGL core profile version string"]? || gl["OpenGL version string"]? || "",
        glsl: gl["OpenGL core profile shading language version string"]? || gl["OpenGL shading language version string"]? || "",
        opengl_es: gl["OpenGL ES profile version string"]? || "", renderer: gl["OpenGL renderer string"]? || "",
        vulkan: vk["apiVersion"]? || "", vulkan_driver: [vk["driverName"]? || "", vk["driverInfo"]? || ""].reject(&.empty?).join(" · "))
    end
  end

  def parse_opengl(text : String, vendor : String, device : String) : Hash(String, String)
    ids = {"Vendor" => vendor, "Device" => device}
    return {} of String => String unless ids.all? do |key, id|
                                           expected = id.to_u32?(16)
                                           line = text.lines.find { |line| line.strip.starts_with?("#{key}:") }
                                           expected && line.try(&.match(/\(0x([0-9a-f]+)\)\s*$/i)).try(&.[1].to_u32?(16)) == expected
                                         end
    return {} of String => String unless text.lines.any? { |line| line.strip == "Accelerated: yes" }
    Inventory.parse_fields(text, ':')
  end

  def parse_vulkan(text : String) : Array(Hash(String, String))
    text.split(/^GPU\d+:\s*$/m).skip(1).map { |block| Inventory.parse_fields(block, '=') }
  end

  private def run(command : String, arguments : Array(String), environment : Hash(String, String)) : String
    executable = Process.find_executable(command)
    timeout = Process.find_executable("timeout")
    return "" unless executable && timeout
    process = SubprocessOutput.launch([timeout, "--signal=TERM", "--kill-after=0.2s", "2s", executable] + arguments,
      environment.merge({"LC_ALL" => "C", "LANG" => "C"}))
    output = SubprocessOutput.read(process)
    process.successful ? output : ""
  rescue IO::Error | GLib::Error
    ""
  end
end
