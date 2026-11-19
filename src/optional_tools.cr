require "./inventory"
require "c/dlfcn"

module SystemView::OptionalTools
  extend self

  def missing(files : LinuxFiles, executable : Proc(String, Bool) = ->(name : String) { !Process.find_executable(name).nil? }) : Array(String)
    if OptionalToolSimulation.enabled?
      return ["glxinfo", "vulkaninfo", "pactl", "timeout", "dmidecode", "pkexec", "libcups"]
    end
    names = {"glxinfo", "vulkaninfo", "pactl", "timeout"}.reject { |name| executable.call(name) }
    unless files.sandboxed?
      names << "dmidecode" unless FirmwareQuery.decoder
      names << "pkexec" unless FirmwareQuery.pkexec
    end
    library = LibC.dlopen("libcups.so.2", LibC::RTLD_LAZY)
    if library.null?
      names << "libcups"
    else
      LibC.dlclose(library)
    end
    names
  end

  def install_command(files : LinuxFiles, missing : Array(String), executable : Proc(String, Bool) = ->(name : String) { !Process.find_executable(name).nil? }) : String?
    return nil if files.sandboxed?
    os = Inventory.parse_fields(files.read("/etc/os-release"), '=')
    families = [os["ID"]? || "", os["ID_LIKE"]? || ""].join(" ").downcase.split
    prefix, packages = if families.any? { |family| family.in?({"arch", "manjaro"}) } && executable.call("pacman")
                         {"sudo pacman -S --needed", {"glxinfo" => "mesa-utils", "vulkaninfo" => "vulkan-tools", "pactl" => "libpulse", "timeout" => "coreutils", "dmidecode" => "dmidecode", "pkexec" => "polkit", "libcups" => "libcups"}}
                       elsif families.any? { |family| family.in?({"debian", "ubuntu"}) } && executable.call("apt")
                         {"sudo apt install", {"glxinfo" => "mesa-utils", "vulkaninfo" => "vulkan-tools", "pactl" => "pulseaudio-utils", "timeout" => "coreutils", "dmidecode" => "dmidecode", "pkexec" => "pkexec", "libcups" => "libcups2"}}
                       elsif families.includes?("fedora") && executable.call("dnf")
                         {"sudo dnf install", {"glxinfo" => "glx-utils", "vulkaninfo" => "vulkan-tools", "pactl" => "pulseaudio-utils", "timeout" => "coreutils", "dmidecode" => "dmidecode", "pkexec" => "polkit", "libcups" => "cups-libs"}}
                       elsif families.any? { |family| family.in?({"opensuse", "opensuse-leap", "opensuse-tumbleweed", "suse"}) } && executable.call("zypper")
                         {"sudo zypper install", {"glxinfo" => "Mesa-demo-x", "vulkaninfo" => "vulkan-tools", "pactl" => "pulseaudio-utils", "timeout" => "coreutils", "dmidecode" => "dmidecode", "pkexec" => "polkit", "libcups" => "libcups2"}}
                       else
                         return nil
                       end
    selected = missing.compact_map { |name| packages[name]? }.uniq
    return nil if selected.empty?
    "#{prefix} #{selected.join(' ')}"
  end

  def nixos_packages(files : LinuxFiles, missing : Array(String)) : Array(String)?
    return nil if files.sandboxed?
    os = Inventory.parse_fields(files.read("/etc/os-release"), '=')
    return nil unless os["ID"]? == "nixos"
    packages = {"glxinfo" => "mesa-demos", "vulkaninfo" => "vulkan-tools", "pactl" => "pulseaudio", "timeout" => "coreutils", "dmidecode" => "dmidecode", "libcups" => "cups"}
    missing.compact_map { |name| packages[name]? }.uniq
  end
end
