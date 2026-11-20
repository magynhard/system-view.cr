require "spec"
require "../src/disk_view_launcher"
require "../src/subprocess_output"
require "file_utils"

describe SystemView::DiskViewLauncher do
  it "removes AppImage resources from the launched application's environment" do
    values = {
      "APPDIR"                 => "/tmp/system-view-appdir",
      "APPIMAGE"               => "/tmp/SystemView.AppImage",
      "PATH"                   => "/tmp/system-view-appdir/usr/bin:/usr/bin",
      "LD_LIBRARY_PATH"        => "/tmp/system-view-appdir/usr/lib:/opt/custom/lib",
      "LD_PRELOAD"             => "/tmp/system-view-appdir/usr/lib/libtest.so /opt/custom/libtest.so",
      "XDG_DATA_DIRS"          => "/tmp/system-view-appdir/usr/share:/usr/local/share:/usr/share",
      "GIO_MODULE_DIR"         => "/tmp/system-view-appdir/usr/lib/gio/modules",
      "GSETTINGS_SCHEMA_DIR"   => "/tmp/system-view-appdir/usr/share/glib-2.0/schemas",
      "GDK_PIXBUF_MODULE_FILE" => "/opt/custom/loaders.cache",
    }
    original = values.keys.to_h { |name| {name, ENV[name]?} }
    begin
      values.each { |name, value| ENV[name] = value }
      launcher = Gio::SubprocessLauncher.new(Gio::SubprocessFlags::StdoutPipe | Gio::SubprocessFlags::StderrSilence)
      SystemView::DiskViewLauncher.clean_appimage_environment(launcher)
      environment = SystemView::SubprocessOutput.read(launcher.spawnv(["/usr/bin/env"])).lines.map(&.chomp)
      environment.should contain("PATH=/usr/bin")
      environment.should contain("LD_LIBRARY_PATH=/opt/custom/lib")
      environment.should contain("LD_PRELOAD=/opt/custom/libtest.so")
      environment.should contain("XDG_DATA_DIRS=/usr/local/share:/usr/share")
      environment.should contain("GDK_PIXBUF_MODULE_FILE=/opt/custom/loaders.cache")
      %w[APPDIR APPIMAGE GIO_MODULE_DIR GSETTINGS_SCHEMA_DIR].each do |name|
        environment.any?(&.starts_with?("#{name}=")).should be_false
      end
      values.each { |name, value| ENV[name]?.should eq(value) }
    ensure
      original.each do |name, value|
        if value
          ENV[name] = value
        else
          ENV.delete(name)
        end
      end
    end
  end

  it "preserves the environment outside an AppImage" do
    appdir = ENV["APPDIR"]?
    begin
      ENV.delete("APPDIR")
      launcher = Gio::SubprocessLauncher.new(Gio::SubprocessFlags::StdoutPipe | Gio::SubprocessFlags::StderrSilence)
      SystemView::DiskViewLauncher.clean_appimage_environment(launcher)
      environment = SystemView::SubprocessOutput.read(launcher.spawnv(["/usr/bin/env"])).lines.map(&.chomp)
      environment.should contain("PATH=#{ENV["PATH"]}")
    ensure
      ENV["APPDIR"] = appdir if appdir
    end
  end

  it "finds a host Flatpak desktop entry without exposing a sandbox path" do
    root = File.tempname("system-view-host")
    directory = File.join(root, "home/test/.local/share/flatpak/exports/share/applications")
    begin
      FileUtils.mkdir_p(directory)
      SystemView::DiskViewLauncher.host_desktop_file("/home/test", "", root).should be_nil
      File.write(File.join(directory, SystemView::DiskViewLauncher::DESKTOP_ID), "[Desktop Entry]\n")
      SystemView::DiskViewLauncher.host_desktop_file("/home/test", "", root).should eq(
        "/home/test/.local/share/flatpak/exports/share/applications/de.magynhard.DiskView.desktop")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
