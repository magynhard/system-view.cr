require "spec"
require "../src/firmware"
require "../src/optional_tools"
require "../src/audio_session"
require "../src/graphics_diagnostics"
require "./support/fixture_files"

describe SystemView::OptionalTools do
  it "simulates all missing tools when explicitly requested" do
    previous = ENV["SYSTEM_VIEW_TEST_MISSING_TOOLS"]?
    begin
      ENV["SYSTEM_VIEW_TEST_MISSING_TOOLS"] = "1"
      SystemView::OptionalTools.missing(FixtureFiles.new).should eq(["glxinfo", "vulkaninfo", "pactl", "timeout", "dmidecode", "pkexec", "libcups"])
      SystemView::FirmwareQuery.available?.should be_false
      SystemView::FirmwareQuery.decoder.should be_nil
      SystemView::FirmwareQuery.pkexec.should be_nil
      SystemView::PrinterDiscovery.scan.available.should be_false
      SystemView::PrinterDiscovery.cups_names.should be_nil
      SystemView::AudioSessionDiscovery.scan.should eq(SystemView::AudioSession.new)
      card = SystemView::GraphicsCard.new("GPU", "1234", "abcd", "", "0000:01:00.0", 0_u64)
      result = SystemView::GraphicsDiagnostics.scan([card]).first
      result.opengl.should be_empty
      result.vulkan.should be_empty
    ensure
      if previous
        ENV["SYSTEM_VIEW_TEST_MISSING_TOOLS"] = previous
      else
        ENV.delete("SYSTEM_VIEW_TEST_MISSING_TOOLS")
      end
    end
  end

  it "maps missing tools to distribution packages without duplicates" do
    files = FixtureFiles.new
    available = ->(_name : String) { true }
    unavailable = ->(_name : String) { false }
    files.files["/etc/os-release"] = "ID=manjaro\nID_LIKE=arch\n"
    SystemView::OptionalTools.install_command(files, ["glxinfo", "vulkaninfo", "pactl"], available).should eq("sudo pacman -S --needed mesa-utils vulkan-tools libpulse")
    files.files["/etc/os-release"] = "ID=ubuntu\nID_LIKE=debian\n"
    SystemView::OptionalTools.install_command(files, ["pactl", "pkexec"], available).should eq("sudo apt install pulseaudio-utils pkexec")
    SystemView::OptionalTools.install_command(files, ["pactl"], unavailable).should be_nil
    files.files["/etc/os-release"] = "ID=fedora\n"
    SystemView::OptionalTools.install_command(files, ["glxinfo", "pactl", "libcups"], available).should eq("sudo dnf install glx-utils pulseaudio-utils cups-libs")
    files.files["/etc/os-release"] = "ID=opensuse-tumbleweed\nID_LIKE=opensuse suse\n"
    SystemView::OptionalTools.install_command(files, ["glxinfo", "pactl", "libcups"], available).should eq("sudo zypper install Mesa-demo-x pulseaudio-utils libcups2")
    SystemView::OptionalTools.install_command(files, ["glxinfo"], unavailable).should be_nil
    files.files["/etc/os-release"] = "ID=nixos\n"
    SystemView::OptionalTools.nixos_packages(files, ["glxinfo", "vulkaninfo", "dmidecode", "pkexec"]).should eq(["mesa-demos", "vulkan-tools", "dmidecode"])
    SystemView::OptionalTools.install_command(files, ["glxinfo"], available).should be_nil
    files.files["/etc/os-release"] = "ID=other\n"
    SystemView::OptionalTools.install_command(files, ["pactl"], available).should be_nil
  end
end
