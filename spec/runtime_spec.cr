require "spec"
require "./support/fixture_files"

class SandboxedRuntimeFiles < FixtureFiles
  def initialize
    super
    @sandboxed = true
  end

  def host_read(path : String) : String
    read(path)
  end

  def host_exists?(path : String) : Bool
    exists?(path)
  end
end

describe SystemView::Inventory do
  it "identifies session, host container and virtual machine without confusing the Flatpak sandbox" do
    files = SandboxedRuntimeFiles.new
    files.files["/run/systemd/container"] = "podman"
    files.files["/proc/cpuinfo"] = "flags : fpu hypervisor sse\n"
    files.files["/sys/class/dmi/id/sys_vendor"] = "QEMU"
    runtime = SystemView::Inventory.runtime_info(files, session: "wayland", appimage: false)
    runtime.session.should eq("Wayland")
    runtime.architecture.should_not be_empty
    runtime.virtualization.should eq("KVM/QEMU")
    runtime.container.should eq("Podman")
    runtime.app_format.should eq("Flatpak")
  end

  it "does not infer physical hardware or a container from missing data" do
    files = FixtureFiles.new
    runtime = SystemView::Inventory.runtime_info(files, session: "unknown", appimage: true)
    runtime.session.should be_empty
    runtime.virtualization.should be_empty
    runtime.container.should be_empty
    runtime.app_format.should eq("AppImage")
    files.files["/proc/cpuinfo"] = "flags : fpu hypervisor sse\n"
    SystemView::Inventory.runtime_info(files, session: "x11").virtualization.should eq("virtual-machine")
    SystemView::Inventory.runtime_info(files, session: "x11").session.should eq("X11")
  end

  it "detects containers and hypervisors from explicit markers" do
    files = FixtureFiles.new
    files.files["/.dockerenv"] = ""
    files.files["/sys/hypervisor/type"] = "xen"
    runtime = SystemView::Inventory.runtime_info(files, session: "tty", appimage: false)
    runtime.session.should eq("TTY")
    runtime.container.should eq("Docker")
    runtime.virtualization.should eq("Xen")
  end
end
