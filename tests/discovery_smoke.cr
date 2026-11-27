require "file_utils"
require "libadwaita"
require "../src/i18n"
require "../src/metadata"
require "../src/app"
require "../spec/support/fixture_files"

if ARGV == [SystemView::PrinterDiscovery::HELPER_ARGUMENT]
  names = SystemView::PrinterDiscovery.cups_names
  exit 1 unless names
  puts names.to_json
  exit
end

# Exercise the actual child-process path while GTK occupies the main thread.
# Parser fixtures and injected graphics loaders cannot detect scheduler deadlocks.
tools = File.tempname("system-view-diagnostic-tools")
Dir.mkdir(tools)
at_exit { FileUtils.rm_rf(tools) }
reports = {
  "vulkaninfo" => "GPU0:\napiVersion = 1.3.280\nvendorID = 0x1234\ndeviceID = 0xabcd\ndeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n",
  "glxinfo"    => "Vendor: Example (0x1234)\nDevice: Example GPU (0xabcd)\nAccelerated: yes\nOpenGL core profile version string: 4.6\n",
}
reports.each do |name, report|
  path = File.join(tools, name)
  File.write(path, "#!/bin/sh\nprintf '%s\\n' #{report.lines.map { |line| "'#{line}'" }.join(" ")}\n")
  File.chmod(path, 0o755)
end
ENV["PATH"] = "#{tools}:#{ENV["PATH"]? || "/usr/bin:/bin"}"
ENV["XDG_DATA_HOME"] = tools
ENV["APPDIR"] = File.join(tools, "appdir")
ENV["APPIMAGE"] = File.join(tools, "SystemView.AppImage")
ENV["LD_LIBRARY_PATH"] = "#{ENV["APPDIR"]}/usr/lib:#{ENV["LD_LIBRARY_PATH"]? || "/usr/lib"}"
FileUtils.mkdir_p(File.join(tools, "applications"))
launch_log = File.join(tools, "disk-view-launches")
fake_disk_view = File.join(tools, "fake-disk-view")
File.write(fake_disk_view, "#!/bin/sh\nprintf 'launch\\n' >> '#{launch_log}'\n")
File.chmod(fake_disk_view, 0o755)
File.write(File.join(tools, "applications", SystemView::DiskViewLauncher::DESKTOP_ID),
  "[Desktop Entry]\nType=Application\nName=Disk View test\nExec=#{fake_disk_view}\n")

def discovery_widgets(widget : Gtk::Widget) : Array(Gtk::Widget)
  result = [widget] of Gtk::Widget
  child = widget.first_child
  while child
    result.concat(discovery_widgets(child))
    child = child.next_sibling
  end
  result
end

SystemView::I18n.setup
app = SystemView::App.new
factory = -> do
  SystemView::RESOURCE._register
  window = SystemView::Window.new(app, FixtureFiles.new, desktop_name: "Test desktop",
    network_loader: -> { SystemView::Connectivity.new },
    display_loader: ->(monitors : Array(SystemView::Monitor)) { SystemView::DisplayConfig.enrich(monitors, nil) })
  window.present
  ticks = 0
  phase = 0
  GLib.timeout(100.milliseconds) do
    begin
      ticks += 1
      raise "Discovery did not finish with real diagnostic subprocesses" if ticks > 60
      tree = discovery_widgets(window)
      if error = tree.select(Adw::StatusPage).find { |page| page.title == "Could not read system information" }
        raise "Discovery failed: #{error.description}"
      end
      rows = tree.select(Adw::ActionRow)
      if phase == 0 && rows.any? { |row| row.subtitle.to_s.includes?("Example CPU 9000") }
        navigation = tree.select(Gtk::ListBox).find { |list| list.has_css_class("navigation-sidebar") }.not_nil!
        navigation.select_row(discovery_widgets(navigation).select(Gtk::ListBoxRow).find! { |row| row.name == "graphics" })
        phase = 1
      elsif phase == 1
        raise "OpenGL subprocess output was lost" unless rows.any? { |row| row.title == "OpenGL" && row.subtitle == "4.6" }
        raise "Vulkan subprocess output was lost" unless rows.any? { |row| row.title == "Vulkan" && row.subtitle == "1.3.280" }
        navigation = tree.select(Gtk::ListBox).find { |list| list.has_css_class("navigation-sidebar") }.not_nil!
        navigation.select_row(discovery_widgets(navigation).select(Gtk::ListBoxRow).find! { |row| row.name == "drives" })
        phase = 2
      elsif phase == 2
        button = tree.select(Gtk::Button).find { |item| item.tooltip_text == "Open Disk View" }.not_nil!
        button.clicked_signal.emit
        button.clicked_signal.emit
        GC.collect
        phase = 3
      elsif phase == 3 && File.file?(launch_log) && File.read(launch_log).lines.size >= 2
        puts "PASS: real graphics subprocesses and repeated Disk View launches complete while GTK is running"
        window.close
        app.quit
        phase = 4
      end
      phase < 4
    rescue error
      STDERR.puts(error.inspect_with_backtrace)
      exit(1)
    end
  end
  window
end
app.window_factory = factory
exit(SystemView::GtkRuntime.run(app))
