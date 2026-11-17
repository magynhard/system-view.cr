require "libadwaita"
require "../src/i18n"
require "../src/metadata"
require "../src/app"
require "../spec/support/fixture_files"
require "../spec/support/network_fixture"
require "../spec/support/display_fixture"

# Exercise real filesystem I/O in the discovery worker. In-memory fixtures alone
# cannot detect workers that lack Crystal's I/O execution context.
class IOFixtureFiles < FixtureFiles
  @cpuinfo_path = File.tempname("system-view-cpuinfo", nil)

  def initialize
    super
    File.write(@cpuinfo_path, files["/proc/cpuinfo"])
  end

  def read(path : String) : String
    path == "/proc/cpuinfo" ? File.read(@cpuinfo_path).strip : super
  end

  def cleanup
    File.delete(@cpuinfo_path)
  end
end

def descendants(widget : Gtk::Widget) : Array(Gtk::Widget)
  result = [widget] of Gtk::Widget
  child = widget.first_child
  while child
    result.concat(descendants(child))
    child = child.next_sibling
  end
  result
end

def check(condition : Bool, message : String)
  raise message unless condition
  puts "PASS: #{message}"
end

def screenshot(window : Gtk::Window, name : String)
  snapshot = Gtk::Snapshot.new
  Gtk::WidgetPaintable.new(window).snapshot(snapshot, window.width.to_f64, window.height.to_f64)
  texture = window.renderer.not_nil!.render_texture(snapshot.to_node.not_nil!, nil)
  check(texture.save_to_png("build/#{name}.png"), "screenshot #{name}")
end

SystemView::I18n.setup
gtk_thread = Thread.current
app = SystemView::App.new
factory = -> do
  SystemView::RESOURCE._register
  Gtk::IconTheme.for_display(Gdk::Display.default.not_nil!).add_resource_path("/de/magynhard/SystemView/icons")
  files = IOFixtureFiles.new
  files.files["/sys/class/dmi/id/sys_vendor"] = "Example Vendor"
  files.files["/sys/class/dmi/id/product_name"] = "Redundant Board"
  2.times { |index| files.files["/run/udev/data/+dmi:id"] += "E:MEMORY_DEVICE_#{index}_MANUFACTURER=Example Memory\n" }
  files.links["/sys/class/drm/card0/device"] = "0000:01:00.0"
  at_exit { files.cleanup }
  firmware = SystemView::Firmware.parse("Handle 0x0016, DMI type 4, 48 bytes\nProcessor Information\n\tSocket Designation: AM4\n\tVoltage: 1.1 V\n\tExternal Clock: 100 MHz\n\tCurrent Speed: 3400 MHz\n\tMax Speed: 4650 MHz\n\tUpgrade: Socket AM4\nHandle 0x0017, DMI type 17, 40 bytes\nMemory Device\n\tSize: 16 GB\n\tLocator: DIMM 0\n\tManufacturer: Unknown\n\tPart Number: CMK32GX4M2E3200C16\n\tConfigured Voltage: 1.2 V\n")
  firmware.processors.first.capabilities << "MMX (MMX technology supported)"
  firmware.memory[0] = firmware.memory.first.copy_with(manufacturer: "Corsair")
  requests = Atomic(Int32).new(0)
  loader = -> do
    attempt = requests.add(1)
    sleep 350.milliseconds
    attempt == 0 ? SystemView::FirmwareResult.new(cancelled: true) : SystemView::FirmwareResult.new(details: firmware)
  end
  network_loader = -> do
    # Force collection in the worker with old UI wrappers awaiting release.
    # Finalizers must still be drained by the GTK loop, never by this worker.
    GC.collect
    SystemView::NetworkDiscovery.scan(network_files, FixtureNetworkBus.new)
  end
  graphics_loader = ->(cards : Array(SystemView::GraphicsCard)) do
    cards.map_with_index do |card, index|
      index == 0 ? card.copy_with(clock_mhz: 1800_u64, memory_clock_mhz: 1124_u64, opengl: "4.6", glsl: "4.60", opengl_es: "3.2", vulkan: "1.3.280", vulkan_driver: "Example driver") : card
    end
  end
  display_loader = ->(monitors : Array(SystemView::Monitor)) { SystemView::DisplayConfig.enrich(monitors, display_reply) }
  window = SystemView::Window.new(app, files, desktop_name: "GNOME 50.5", firmware_loader: loader,
    network_loader: network_loader, graphics_loader: graphics_loader, display_loader: display_loader)
  window.present
  phase = -8
  ticks = 0
  GLib.timeout(200.milliseconds) do
    begin
      ticks += 1
      raise "UI test timed out" if ticks > 60
      widgets = descendants(window)
      if error_page = widgets.select(Adw::StatusPage).find { |page| page.title == "Could not read system information" }
        raise "Discovery failed: #{error_page.description}"
      end
      split = widgets.select(Adw::OverlaySplitView).first
      navigation = widgets.select(Gtk::ListBox).find { |list| list.has_css_class("navigation-sidebar") }.not_nil!
      rows = widgets.select(Adw::ActionRow)
      banner = widgets.select(Adw::Banner).first
      unlock_action = window.lookup_action("hardware-details").not_nil!
      case phase
      when -8
        if rows.any? { |row| row.subtitle.try(&.includes?("Example CPU 9000")) }
          check(Thread.current == gtk_thread, "GTK callbacks stay on the original application thread")
          navigation.select_row(navigation.row_at_index(2))
          locked_rows = descendants(window).select(Adw::ActionRow)
          check(banner.revealed? && banner.title == "Some hardware details are locked", "CPU page shows the unlock banner")
          socket = locked_rows.find { |row| row.title == "Socket" }.not_nil!
          check(!socket.sensitive? && socket.subtitle.to_s.empty?, "locked CPU fields are visible, empty and disabled")
          features = locked_rows.find { |row| row.title == "Processor Features" }.not_nil!
          check(!features.sensitive? && features.subtitle.to_s.empty?, "renamed processor features are visible before unlocking")
          check(locked_rows.none? { |row| row.title == "Flags" }, "raw CPU flags section is removed")
          phase = -7
        end
      when -7
        screenshot(window, "system-view-processor-locked")
        navigation.select_row(navigation.row_at_index(5))
        locked_rows = descendants(window).select(Adw::ActionRow).select { |row| {"Voltage", "Minimum voltage", "Maximum voltage"}.includes?(row.title) }
        check(banner.revealed? && !locked_rows.empty?, "RAM page shares the unlock banner and has voltage placeholders")
        check(locked_rows.all? { |row| !row.sensitive? && row.subtitle.to_s.empty? }, "all locked RAM voltages are empty and disabled")
        phase = -6
      when -6
        screenshot(window, "system-view-memory-locked")
        window.set_default_size(360, 780)
        phase = -5
      when -5
        if window.width.in?(340..380) && split.collapsed?
          check(banner.revealed?, "unlock banner fits the narrow layout")
          screenshot(window, "system-view-memory-locked-narrow")
          window.set_default_size(1040, 780)
          phase = -4
        end
      when -4
        next true unless window.width >= 1000 && !split.collapsed?
        button = descendants(banner).select(Gtk::Button).first
        check(button.has_css_class("suggested-action"), "unlock button uses primary styling")
        check(banner.button_label == "Unlock…", "banner labels its unlock action")
        button.clicked_signal.emit
        check(!unlock_action.enabled?, "unlock is disabled while authorization is pending")
        navigation.select_row(navigation.row_at_index(2))
        unlock_action.activate(nil)
        phase = -3
      when -3
        if requests.get >= 1 && unlock_action.enabled?
          socket = rows.find { |row| row.title == "Socket" }.not_nil!
          check(banner.revealed? && !socket.sensitive? && socket.subtitle.to_s.empty?, "cancelled authorization leaves all hardware details locked")
          descendants(banner).select(Gtk::Button).first.clicked_signal.emit
          phase = -2
        end
      when -2
        if !banner.revealed?
          socket = rows.find { |row| row.title == "Socket" }.not_nil!
          check(socket.sensitive? && socket.subtitle == "AM4", "successful unlock populates and enables CPU fields")
          check(!unlock_action.enabled?, "already unlocked details cannot start another query")
          navigation.select_row(navigation.row_at_index(5))
          phase = -1
        end
      when -1
        voltage = rows.find { |row| row.title == "Voltage" }.not_nil!
        check(!banner.revealed? && voltage.sensitive? && voltage.subtitle == "1.2 V", "one successful authorization also unlocks RAM")
        check(rows.find { |row| row.title == "Maximum voltage" }.not_nil!.subtitle == "1.35 V", "unlock retains readable values absent from the additional response")
        unlock_action.activate(nil)
        check(requests.get == 2, "switching sections reuses the successful unlock without another query")
        navigation.select_row(navigation.row_at_index(0))
        phase = 0
      when 0
        if rows.any? { |row| row.subtitle.try(&.includes?("Example CPU 9000")) }
          check(navigation.selected_row.not_nil!.name == "overview", "overview selected on startup")
          check(navigation.row_at_index(1).not_nil!.header.is_a?(Gtk::Separator), "overview separated from hardware sections")
          check(!split.collapsed? && split.show_sidebar?, "wide sidebar is visible (width=#{window.width}, collapsed=#{split.collapsed?}, shown=#{split.show_sidebar?})")
          check(rows.any? { |row| row.subtitle.try(&.includes?("Exact GPU 5000")) }, "resolved GPU model displayed")
          check(rows.any? { |row| row.title == "Graphics" && row.subtitle.try(&.includes?(" · 7.5 GiB")) }, "overview includes GPU memory beside manufacturer and model")
          check(rows.any? { |row| row.subtitle.try(&.includes?("Example NVMe 1TB")) }, "physical drives displayed")
          check(rows.any? { |row| row.title == "Memory" && row.subtitle == "Example Memory · TEST-16G-DDR4 · 32.0 GiB · DDR4" }, "overview shows the identical RAM manufacturer/model before capacity and type")
          check(widgets.select(Gtk::Label).none? { |label| label.text.includes?("Redundant Board") }, "overview subtitle contains only the operating system, without the computer model")
          check(widgets.select(Gtk::Label).none? { |label| label.text == "Memory (RAM)" }, "memory navigation uses the shorter name")
          check(rows.any? { |row| row.title == "Monitors" && row.subtitle == "Dell · ExamplePanel · 1920 × 1080 · DP-1" }, "overview shows monitor connection after its preferred resolution")
          check(rows.any? { |row| row.title == "Desktop Environment" && row.subtitle == "GNOME 50.5" }, "overview includes desktop name and version")
          check(rows.any? { |row| row.title == "Uptime" && row.subtitle == "2 d 4 h 33 min" }, "overview shows the uptime")
          uptime = rows.find { |row| row.title == "Uptime" }.not_nil!
          check(descendants(uptime).select(Gtk::Image).any? { |image| image.icon_name == "preferences-system-time-symbolic" }, "uptime row has a clock icon")
          network_row = rows.find { |row| row.title == "Network" }.not_nil!
          check(network_row.subtitle.to_s.includes?("Ethernet (LAN) · enp1s0 · Connected · 2.5 Gbit/s · 192.0.2.10"), "LAN overview row includes the IPv4 address")
          check(network_row.subtitle.to_s.includes?("Bluetooth · Example Bluetooth · Active"), "Bluetooth overview row reports an active adapter")
          kernel = rows.find { |row| row.title == "Kernel" }.not_nil!
          check(descendants(kernel).select(Gtk::Image).any? { |image| image.icon_name == "system-view-processor-symbolic" }, "kernel row has a leading icon")
          screenshot(window, "system-view-overview")
          { {"Processor", "processor"}, {"Mainboard", "mainboard"}, {"Graphics", "graphics"},
           {"Monitors", "monitors"}, {"Memory", "memory"}, {"Storage", "drives"},
           {"Network", "network"}, {"Operating System", "system"}, {"Kernel", "system"},
           {"Desktop Environment", "system"}, {"Uptime", "system"} }.each do |title, page|
            item = descendants(window).select(Adw::ActionRow).find { |row| row.title == title }.not_nil!
            check(item.activatable?, "overview #{title} is keyboard/click activatable")
            item.activate
            check(navigation.selected_row.not_nil!.name == page, "overview #{title} opens its matching section")
            navigation.select_row(navigation.row_at_index(0))
          end
          (1..10).each do |index|
            navigation.select_row(navigation.row_at_index(index))
            detail_rows = descendants(window).select(Adw::ActionRow)
            check(!detail_rows.empty?, "detail page #{index} has real information")
            check(detail_rows.none? { |row| {"Capacity source", "Model identification"}.includes?(row.title) }, "detail page #{index} omits data provenance")
            check(descendants(window).select(Adw::PreferencesGroup).all? { |group| group.description.to_s.empty? }, "detail page #{index} omits implementation explanations")
            if index == 1
              check(detail_rows.any? { |row| row.title == "GPU model" && row.subtitle == "Unknown" }, "generic PCI family is not presented as an exact model")
              check(detail_rows.any? { |row| row.title == "Dedicated video memory" && row.subtitle == "7.5 GiB" }, "video memory uses base 1024 and GiB")
              check(detail_rows.any? { |row| row.title == "Current GPU clock" && row.subtitle == "1800 MHz" }, "GPU page shows the current clock")
              check(detail_rows.any? { |row| row.title == "OpenGL" && row.subtitle == "4.6" }, "GPU page shows verified OpenGL support")
              check(detail_rows.any? { |row| row.title == "Vulkan" && row.subtitle == "1.3.280" }, "GPU page shows the physical-device Vulkan version")
              check(detail_rows.any? { |row| row.title == "Connected monitors" && row.subtitle.try(&.includes?("75.0 Hz")) }, "GPU page links its attached displays and refresh rates")
            elsif index == 2
              check(detail_rows.any? { |row| row.title == "Socket" && row.subtitle == "AM4" }, "additional CPU details include the physical socket type")
              check(detail_rows.any? { |row| row.title == "Processor Features" && row.subtitle.try(&.includes?("MMX")) }, "processor features retain their firmware values under the new label")
              check(detail_rows.none? { |row| row.title == "Flags" }, "CPU flags are no longer displayed")
              check(descendants(window).select(Adw::PreferencesGroup).none? { |group| group.title == "Instruction sets and CPU features" }, "the instruction-set section is removed entirely")
              check(detail_rows.count { |row| row.title == "CPU family" } == 1, "CPU identification is not duplicated")
              check(detail_rows.any? { |row| row.title == "Socket count" && row.subtitle == "1" }, "CPU socket quantity is explicitly labelled")
              check(detail_rows.any? { |row| row.title == "Base clock" && row.subtitle == "3.4 GHz" }, "CPU details show clock speeds")
              check(detail_rows.any? { |row| row.title == "L3 cache (Data and instructions)" && row.subtitle.try(&.includes?("32.0 MiB total")) }, "shared L3 cache is counted once")
            elsif index == 5
              check(detail_rows.any? { |row| row.title == "Voltage" && row.subtitle == "1.2 V" }, "precise module voltage is displayed")
              check(detail_rows.any? { |row| row.subtitle.try(&.includes?("Corsair Vengeance LPX · CMK32GX4M2E3200C16")) }, "RAM manufacturer and series precede the model identifier")
              check(detail_rows.first.title == "Installed RAM" && detail_rows.first.subtitle == "32.0 GiB", "installed capacity comes first on RAM page")
              check(detail_rows.any? { |row| row.title == "Usable RAM" && row.subtitle == "30.5 GiB" }, "RAM details use base 1024 and GiB")
              check(detail_rows.any? { |row| row.subtitle.try(&.includes?("TEST-16G-DDR4")) }, "RAM page includes module identification")
              check(detail_rows.count { |row| row.title == "Timings (CL–tRCD–tRP–tRAS)" && row.subtitle == "Not reported" } == 2, "each module exposes missing timings without inferring them from its part number")
            elsif index == 6
              check(detail_rows.any? { |row| row.subtitle == "ExamplePanel" }, "monitor details are populated")
              check(descendants(window).select(Adw::PreferencesGroup).any? { |group| group.title == "Monitor 2 (Primary)" }, "monitor titles use desktop numbering and primary status instead of the model")
              check(detail_rows.any? { |row| row.title == "Current refresh rate" && row.subtitle == "75.0 Hz" }, "monitor current refresh is distinct from its preferred timing")
            elsif index == 7
              check(detail_rows.any? { |row| row.subtitle == "Example USB Audio" }, "audio details are populated")
            elsif index == 8
              check(detail_rows.any? { |row| row.subtitle == "Keyboard" }, "input devices are classified")
            elsif index == 9
              check(detail_rows.any? { |row| row.title == "Link speed" && row.subtitle == "2.5 Gbit/s" }, "LAN link speed uses bits per second")
              check(detail_rows.any? { |row| row.title == "SSID" && row.subtitle == "Test ä" }, "Wi-Fi SSID is decoded correctly")
              check(detail_rows.any? { |row| row.title == "Link speed" && row.subtitle == "866.7 Mbit/s" }, "Wi-Fi link speed is converted from kbit/s")
              check(detail_rows.any? { |row| row.title == "DNS servers" && row.subtitle == "192.0.2.53\n192.0.2.54" }, "LAN DNS servers stay scoped to their interface")
              check(detail_rows.any? { |row| row.title == "Bluetooth version" && row.subtitle == "5.3" }, "Bluetooth adapter details are populated")
              check(detail_rows.any? { |row| row.title == "Link speed" && row.subtitle == "Not reported" }, "Bluetooth speed is not guessed from its version")
              check(!banner.revealed?, "network information needs no hardware unlock banner")
            elsif index == 10
              check(detail_rows.none? { |row| row.title == "Computer model" }, "OS page omits redundant computer model")
              check(detail_rows.any? { |row| row.title == "Uptime" && row.subtitle == "2 d 4 h 33 min" }, "OS page shows the uptime")
            end
          end
          check(widgets.select(Gtk::MenuButton).any? { |button| button.tooltip_text == "Copy system information" }, "copy menu is available in the header bar")
          clipboard = Gdk::Display.default.not_nil!.clipboard
          window.lookup_action("copy-overview").not_nil!.activate(nil)
          check(clipboard.content != nil, "copy overview sets clipboard content")
          window.lookup_action("copy-all").not_nil!.activate(nil)
          check(clipboard.content != nil, "copy all sets clipboard content")
          window.set_default_size(600, 780)
          phase = 1
        end
      when 1
        if window.width.in?(500..620) && split.collapsed? && !split.show_sidebar?
          check(true, "narrow window collapses and hides sidebar")
          split.show_sidebar = true
          phase = 2
        end
      when 2
        check(split.show_sidebar?, "sidebar can be opened as an overlay")
        screenshot(window, "system-view-narrow-sidebar")
        navigation.select_row(navigation.row_at_index(0))
        navigation.row_activated_signal.emit(navigation.row_at_index(0).not_nil!)
        check(!split.show_sidebar?, "selecting a page dismisses overlay")
        window.set_default_size(360, 780)
        phase = 3
      when 3
        if window.width.in?(340..380)
          check(split.collapsed?, "minimum-width layout stays collapsed")
          screenshot(window, "system-view-narrow")
          item = descendants(window).select(Adw::ActionRow).find { |row| row.title == "Memory" }.not_nil!
          item.activate
          check(navigation.selected_row.not_nil!.name == "memory" && !split.show_sidebar?, "overview navigation also works with the collapsed sidebar")
          navigation.select_row(navigation.row_at_index(2))
          window.lookup_action("refresh").not_nil!.activate(nil)
          phase = 4
        end
      when 4
        if window.lookup_action("refresh").not_nil!.enabled?
          check(navigation.selected_row.not_nil!.name == "processor", "refresh preserves selected detail page")
          check(rows.any? { |row| row.subtitle == "Example CPU 9000" }, "asynchronous refresh updates detail data")
          window.set_default_size(1040, 780)
          phase = 5
        end
      when 5
        if window.width >= 1000 && !split.collapsed? && split.show_sidebar?
          check(true, "expanding restores persistent sidebar")
          screenshot(window, "system-view-processor")
          scroll = widgets.select(Gtk::ScrolledWindow).find { |view| descendants(view).any? { |child| child.is_a?(Adw::Clamp) } }.not_nil!
          scroll.vadjustment.value = scroll.vadjustment.upper - scroll.vadjustment.page_size
          phase = 6
        end
      when 6
        screenshot(window, "system-view-caches")
        navigation.select_row(navigation.row_at_index(5))
        phase = 7
      when 7
        scroll = descendants(window).select(Gtk::ScrolledWindow).find { |view| descendants(view).any? { |child| child.is_a?(Adw::Clamp) } }.not_nil!
        check(scroll.vadjustment.value == 0.0, "switching pages starts at the top")
        check(!banner.revealed? && !unlock_action.enabled? && requests.get == 2, "refresh preserves the shared unlocked state")
        screenshot(window, "system-view-memory")
        navigation.select_row(navigation.row_at_index(6))
        phase = 8
      when 8
        screenshot(window, "system-view-monitors")
        navigation.select_row(navigation.row_at_index(7))
        phase = 9
      when 9
        screenshot(window, "system-view-audio")
        navigation.select_row(navigation.row_at_index(8))
        phase = 10
      when 10
        screenshot(window, "system-view-inputs")
        navigation.select_row(navigation.row_at_index(9))
        phase = 11
      when 11
        screenshot(window, "system-view-network")
        window.set_default_size(360, 780)
        phase = 12
      when 12
        if window.width.in?(340..380)
          check(split.collapsed?, "network page supports the minimum-width layout")
          scroll = widgets.select(Gtk::ScrolledWindow).find { |view| descendants(view).any? { |child| child.is_a?(Adw::Clamp) } }.not_nil!
          check(scroll.hadjustment.upper <= scroll.hadjustment.page_size + 1, "network details fit without horizontal scrolling")
          screenshot(window, "system-view-network-narrow")
          window.lookup_action("refresh").not_nil!.activate(nil)
          phase = 13
        end
      when 13
        if window.lookup_action("refresh").not_nil!.enabled?
          check(navigation.selected_row.not_nil!.name == "network", "refresh keeps the network page selected")
          check(rows.any? { |row| row.title == "IP addresses" && row.subtitle == "192.0.2.10/24" }, "refresh reloads per-interface network addresses")
          phase = 14
        end
      when 14
        navigation.select_row(navigation.row_at_index(1))
        phase = 15
      when 15
        screenshot(window, "system-view-graphics-narrow")
        window.set_default_size(1040, 780)
        phase = 16
      when 16
        next true unless window.width >= 1000
        screenshot(window, "system-view-graphics")
        window.lookup_action("refresh").not_nil!.activate(nil)
        window.close
        app.quit
        check(true, "closing during a refresh is safe")
        phase = 17
      end
      phase < 17
    rescue error
      STDERR.puts(error.inspect_with_backtrace)
      exit(1)
    end
  end
  window
end
app.window_factory = factory
exit(SystemView::GtkRuntime.run(app))
