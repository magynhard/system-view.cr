require "spec"
require "./support/fixture_files"
require "../src/graphics_diagnostics"

GL_REPORT = "Vendor: Example (0x1234)\nDevice: Example GPU (0xabcd)\nAccelerated: yes\nOpenGL core profile version string: 4.6 (Core Profile) Mesa\nOpenGL core profile shading language version string: 4.60\nOpenGL renderer string: Example GPU\nOpenGL ES profile version string: OpenGL ES 3.2\n"
VK_REPORT = "Vulkan Instance Version: 1.4.999\nGPU0:\napiVersion = 1.3.280\nvendorID = 0x1234\ndeviceID = 0xabcd\ndeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\ndriverVersion = 1.2\ndriverName = example\ndriverInfo = Driver 1.2\n"

describe SystemView::GraphicsDiagnostics do
  it "matches hardware PCI IDs and reports the device Vulkan version, not the loader version" do
    calls = [] of Tuple(String, Hash(String, String))
    runner = ->(command : String, args : Array(String), env : Hash(String, String)) do
      calls << {command, env}
      command == "glxinfo" ? GL_REPORT : VK_REPORT
    end
    card = SystemView::Inventory.graphics(FixtureFiles.new).first
    result = SystemView::GraphicsDiagnostics.scan([card], runner).first
    result.opengl.should eq("4.6 (Core Profile) Mesa")
    result.glsl.should eq("4.60")
    result.opengl_es.should eq("OpenGL ES 3.2")
    result.vulkan.should eq("1.3.280")
    result.vulkan_driver.should eq("example · Driver 1.2")
    result.vulkan_device_type.should eq("PHYSICAL_DEVICE_TYPE_DISCRETE_GPU")
    result.vulkan_driver_version.should eq("1.2")
    calls.find { |command, _env| command == "glxinfo" }.not_nil![1]["DRI_PRIME"].should eq("pci-0000_01_00_0")
  end

  it "does not attribute a software renderer or another GPU's OpenGL support to a card" do
    {GL_REPORT.sub("Accelerated: yes", "Accelerated: no"), GL_REPORT.sub("0xabcd", "0xffff")}.each do |report|
      SystemView::GraphicsDiagnostics.parse_opengl(report, "1234", "abcd").should be_empty
    end
  end

  it "does not guess API attribution for identical cards or duplicate Vulkan ICDs" do
    card = SystemView::Inventory.graphics(FixtureFiles.new).first
    runner = ->(_command : String, _args : Array(String), _env : Hash(String, String)) { VK_REPORT + VK_REPORT.sub("GPU0:", "GPU1:") }
    data = SystemView::GraphicsDiagnostics.scan([card], runner)
    data.first.vulkan.should be_empty
    data = SystemView::GraphicsDiagnostics.scan([card, card.copy_with(address: "0000:05:00.0")], runner)
    data.all?(&.opengl.empty?).should be_true
    data.all?(&.vulkan.empty?).should be_true
  end

  it "recognizes identical duplicate ICD reports with a device UUID" do
    card = SystemView::Inventory.graphics(FixtureFiles.new).first
    report = VK_REPORT + "deviceUUID = 00000000-2900-0000-0000-000000000000\n"
    runner = ->(_command : String, _args : Array(String), _env : Hash(String, String)) { report + report.sub("GPU0:", "GPU1:") }
    SystemView::GraphicsDiagnostics.scan([card], runner).first.vulkan.should eq("1.3.280")
  end

  it "retains hardware identification if diagnostics are absent or fail" do
    runner = ->(_command : String, _args : Array(String), _env : Hash(String, String)) { "" }
    card = SystemView::Inventory.graphics(FixtureFiles.new).first
    SystemView::GraphicsDiagnostics.scan([card], runner).first.should eq(card)
  end

  it "reads only active GPU clock steps rather than claiming maximum or idle values" do
    files = FixtureFiles.new
    base = "/sys/bus/pci/devices/0000:01:00.0"
    files.files["#{base}/pp_dpm_sclk"] = "0: 96Mhz\n1: 1800Mhz *\n2: 2700Mhz\n"
    files.files["#{base}/pp_dpm_mclk"] = "0: 96Mhz *\n1: 1124Mhz\n"
    card = SystemView::Inventory.graphics(files).first
    card.clock_mhz.should eq(1800)
    card.memory_clock_mhz.should eq(96)
    SystemView::Inventory.active_graphics_clock("0: 2700MHz\n").should eq(0)
  end
end
