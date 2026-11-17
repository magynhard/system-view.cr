require "file_utils"
require "libadwaita"
require "../src/i18n"
require "../src/metadata"
require "../src/app"
require "../spec/support/fixture_files"

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
        navigation.select_row(navigation.row_at_index(1))
        phase = 1
      elsif phase == 1
        raise "OpenGL subprocess output was lost" unless rows.any? { |row| row.title == "OpenGL" && row.subtitle == "4.6" }
        raise "Vulkan subprocess output was lost" unless rows.any? { |row| row.title == "Vulkan" && row.subtitle == "1.3.280" }
        puts "PASS: real graphics subprocesses complete while the GTK loop is running"
        window.close
        app.quit
        phase = 2
      end
      phase < 2
    rescue error
      STDERR.puts(error.inspect_with_backtrace)
      exit(1)
    end
  end
  window
end
app.window_factory = factory
exit(SystemView::GtkRuntime.run(app))
