require "./firmware"
require "./desktop"
require "./gtk_runtime"
require "./graphics_diagnostics"
require "./display_config"
require "./export"
require "./drive_health"

module SystemView
  class Window < Adw::ApplicationWindow
    include I18n

    @split = Adw::OverlaySplitView.new
    @navigation = Gtk::ListBox.new
    @body = Gtk::Box.new(:vertical, 24)
    @content_scroll = Gtk::ScrolledWindow.new
    @unlock_banner = Adw::Banner.new("")
    @subtitle = Adw::WindowTitle.new("System View", "")
    @refresh = Gio::SimpleAction.new("refresh", nil)
    @snapshot : Snapshot?
    @page = "overview"
    @history = [] of String
    @history_index = -1
    @history_traversal = false
    @back = Gio::SimpleAction.new("back", nil)
    @forward = Gio::SimpleAction.new("forward", nil)
    @closed = false
    @loading = false
    @firmware_action = Gio::SimpleAction.new("hardware-details", nil)
    @firmware_query : FirmwareQuery?
    @firmware : FirmwareDetails?
    @firmware_message = ""
    @two_column_layouts = [] of Gtk::FlowBox

    def initialize(app : Gtk::Application, @files : LinuxFiles = LinuxFiles.new, @firmware : FirmwareDetails? = nil, @desktop_name : String? = nil, @firmware_loader : Proc(FirmwareResult)? = nil, @network_loader : Proc(Connectivity)? = nil,
                   @graphics_loader : Proc(Array(GraphicsCard), Array(GraphicsCard))? = nil,
                   @display_loader : Proc(Array(Monitor), Array(Monitor))? = nil,
                   @drive_health_loader : Proc(Array(Drive), Array(Drive))? = nil)
      super(application: app, title: "System View", default_width: 1040, default_height: 780)
      set_size_request(360, 420)
      setup_actions(app)

      header = Adw::HeaderBar.new
      header.title_widget = @subtitle
      sidebar_header = Adw::HeaderBar.new
      sidebar_header.show_end_title_buttons = false
      sidebar_header.add_css_class("flat")
      sidebar_header.title_widget = Gtk::Box.new(:horizontal, 0)
      header.show_start_title_buttons = false
      sidebar_controls = navigation_controls
      sidebar_controls.name = "sidebar-controls"
      sidebar_header.pack_start(sidebar_controls)
      content_controls = navigation_controls
      content_controls.name = "content-controls"
      header.pack_start(content_controls)
      update_controls = -> do
        content_controls.visible = @split.collapsed? || !@split.show_sidebar?
      end
      @split.notify_signal["show-sidebar"].connect { update_controls.call }
      @split.notify_signal["collapsed"].connect do
        @subtitle.visible = !@split.collapsed?
        @two_column_layouts.each { |columns| columns.min_children_per_line = @split.collapsed? ? 1_u32 : 2_u32 }
        update_controls.call
      end
      update_controls.call
      refresh_button = Gtk::Button.new_from_icon_name("view-refresh-symbolic")
      refresh_button.tooltip_text = translate("Refresh")
      refresh_button.action_name = "win.refresh"
      header.pack_end(refresh_button)
      copy_button = Gtk::MenuButton.new
      copy_button.icon_name = "edit-copy-symbolic"
      copy_button.tooltip_text = translate("Copy system information")
      copy_button.primary = true
      copy_model = Gio::Menu.new
      copy_model.append(translate("Copy summary"), "win.copy-overview")
      copy_model.append(translate("Copy all information"), "win.copy-all")
      copy_button.menu_model = copy_model
      header.pack_end(copy_button)
      menu = Gtk::MenuButton.new
      menu.icon_name = "open-menu-symbolic"
      menu.tooltip_text = translate("Main menu")
      menu.primary = true
      model = Gio::Menu.new
      model.append(translate("About System View"), "win.about")
      model.append(translate("Close"), "win.close")
      menu.menu_model = model
      header.pack_end(menu)

      build_navigation
      sidebar = Gtk::ScrolledWindow.new
      sidebar.hscrollbar_policy = :never
      sidebar.child = @navigation
      sidebar_toolbar = Adw::ToolbarView.new
      sidebar_toolbar.add_css_class("sidebar")
      sidebar_toolbar.add_top_bar(sidebar_header)
      sidebar_toolbar.content = sidebar
      @split.sidebar = sidebar_toolbar
      @split.min_sidebar_width = 210.0
      @split.max_sidebar_width = 260.0
      @body.margin_top = 28
      @body.margin_bottom = 28
      @body.margin_start = 20
      @body.margin_end = 20
      clamp = Adw::Clamp.new
      clamp.maximum_size = 1200
      clamp.child = @body
      scroll = @content_scroll
      scroll.hscrollbar_policy = :never
      scroll.child = clamp
      @unlock_banner.title = translate("Some hardware details are locked")
      @unlock_banner.use_markup = false
      @unlock_banner.action_name = "win.hardware-details"
      page = Gtk::Box.new(:vertical, 0)
      page.append(@unlock_banner)
      page.append(scroll)
      scroll.vexpand = true
      toolbar = Adw::ToolbarView.new
      toolbar.add_top_bar(header)
      toolbar.content = page
      @split.content = toolbar
      self.content = @split

      # The generated constructor passes this transfer-full boxed condition
      # without relinquishing its Crystal wrapper. Create it directly so only
      # the breakpoint owns and frees it.
      condition = LibAdw.adw_breakpoint_condition_new_length(Adw::BreakpointConditionLengthType::MaxWidth.value,
        860.0, Adw::LengthUnit::Px.value)
      breakpoint = Adw::Breakpoint.new(LibAdw.adw_breakpoint_new(condition), GICrystal::Transfer::Full)
      breakpoint.add_setter(@split, "collapsed", true)
      add_breakpoint(breakpoint)
      close_request_signal.connect do
        @closed = true
        @firmware_query.try(&.cancel)
        false
      end
      @navigation.select_row(@navigation.row_at_index(0))
      reload
    end

    private def navigation_controls : Gtk::Box
      controls = Gtk::Box.new(:horizontal, 0)
      toggle = Gtk::ToggleButton.new
      toggle.icon_name = "sidebar-show-symbolic"
      toggle.tooltip_text = translate("Toggle sidebar")
      toggle.add_css_class("flat")
      toggle.active = @split.show_sidebar?
      toggle.toggled_signal.connect { @split.show_sidebar = toggle.active? }
      @split.notify_signal["show-sidebar"].connect { toggle.active = @split.show_sidebar? }
      controls.append(toggle)
      back = Gtk::Button.new_from_icon_name("go-previous-symbolic")
      back.add_css_class("flat")
      back.tooltip_text = translate("Back")
      back.action_name = "win.back"
      controls.append(back)
      forward = Gtk::Button.new_from_icon_name("go-next-symbolic")
      forward.add_css_class("flat")
      forward.tooltip_text = translate("Forward")
      forward.action_name = "win.forward"
      controls.append(forward)
      controls
    end

    private def setup_actions(app : Gtk::Application)
      @back.enabled = false
      @forward.enabled = false
      @back.activate_signal.connect { move_history(-1) }
      @forward.activate_signal.connect { move_history(1) }
      add_action(@back)
      add_action(@forward)
      app.set_accels_for_action("win.back", ["<Alt>Left"])
      app.set_accels_for_action("win.forward", ["<Alt>Right"])
      @refresh.activate_signal.connect { reload }
      add_action(@refresh)
      about = Gio::SimpleAction.new("about", nil)
      about.activate_signal.connect do
        Adw::AboutDialog.new(application_name: "System View", application_icon: APP_ID,
          version: VERSION, developer_name: AUTHOR, developers: ["#{AUTHOR} <#{AUTHOR_EMAIL}>"],
          website: "https://github.com/magynhard/system-view.cr",
          issue_url: "https://github.com/magynhard/system-view.cr/issues",
          comments: translate("Your system and hardware at a glance."),
          license_type: Gtk::License::MitX11, copyright: "© 2026 #{AUTHOR}").present(self)
      end
      add_action(about)
      close = Gio::SimpleAction.new("close", nil)
      close.activate_signal.connect { self.close }
      add_action(close)
      sidebar = Gio::SimpleAction.new("sidebar", nil)
      sidebar.activate_signal.connect { @split.show_sidebar = !@split.show_sidebar? }
      add_action(sidebar)
      app.set_accels_for_action("win.refresh", ["<Primary>r"])
      app.set_accels_for_action("win.sidebar", ["F9"])
      app.set_accels_for_action("win.about", ["F1"])
      app.set_accels_for_action("win.close", ["<Primary>w"])
      @firmware_action.enabled = @firmware.nil? && unlock_available?
      @firmware_action.activate_signal.connect { load_firmware }
      add_action(@firmware_action)
      copy_overview = Gio::SimpleAction.new("copy-overview", nil)
      copy_overview.activate_signal.connect { copy_snapshot(false) }
      add_action(copy_overview)
      copy_all = Gio::SimpleAction.new("copy-all", nil)
      copy_all.activate_signal.connect { copy_snapshot(true) }
      add_action(copy_all)
    end

    private def build_navigation
      @navigation.add_css_class("navigation-sidebar")
      @navigation.selection_mode = :single
      @navigation.margin_top = 8
      @navigation.header_func = ->(row : Gtk::ListBoxRow, _previous : Gtk::ListBoxRow?) do
        if row.name == "graphics"
          separator = Gtk::Separator.new(:horizontal)
          separator.margin_top = 8
          separator.margin_bottom = 8
          separator.margin_start = 12
          separator.margin_end = 12
          row.header = separator
        else
          row.header = nil
        end
        nil
      end
      entries = {
        {"overview", translate("Summary"), "view-grid-symbolic"},
        {"graphics", translate("Graphics"), "system-view-graphics-symbolic"},
        {"processor", translate("Processor"), "system-view-processor-symbolic"},
        {"mainboard", translate("Mainboard"), "system-view-mainboard-symbolic"},
        {"drives", translate("Drives"), "drive-harddisk-symbolic"},
        {"memory", translate("Memory"), "system-view-memory-symbolic"},
        {"monitors", translate("Monitors"), "video-display-symbolic"},
        {"audio", translate("Audio"), "audio-card-symbolic"},
        {"inputs", translate("Input Devices"), "input-keyboard-symbolic"},
        {"network", translate("Network"), "network-wired-symbolic"},
        {"system", translate("Operating System"), "preferences-system-symbolic"},
        {"power", translate("Power"), "battery-symbolic"},
      }
      entries.each do |id, title, icon|
        row = Gtk::ListBoxRow.new
        row.name = id
        row.tooltip_text = title
        box = Gtk::Box.new(:horizontal, 12)
        box.margin_top = 8
        box.margin_bottom = 8
        box.margin_start = 8
        box.margin_end = 8
        box.append(Gtk::Image.new_from_icon_name(icon))
        caption = Gtk::Label.new(title)
        caption.wrap = true
        caption.xalign = 0.0
        box.append(caption)
        row.child = box
        @navigation.append(row)
      end
      @navigation.row_selected_signal.connect do |row|
        if row
          unless @history_traversal || (@history_index >= 0 && @history[@history_index] == row.name)
            @history = @history[0, @history_index + 1]
            @history << row.name
            @history_index = @history.size - 1
            update_history_actions
          end
          @page = row.name
          @subtitle.subtitle = entries.find { |entry| entry[0] == @page }.try(&.[1]) || ""
          render
          @content_scroll.vadjustment.value = 0.0
        end
      end
      # Activating an already-selected row also dismisses the narrow overlay.
      @navigation.row_activated_signal.connect do |_row|
        @split.show_sidebar = false if @split.collapsed?
      end
    end

    private def reload
      return if @loading || @closed
      @loading = true
      @refresh.enabled = false
      results = Channel(Snapshot | Exception).new(1)
      # Filesystem I/O needs a Crystal execution context, which a raw Thread
      # does not provide. Keep discovery isolated from the GTK main thread.
      Fiber::ExecutionContext::Isolated.new("system-discovery") do
        begin
          connectivity = @network_loader.try(&.call) || NetworkDiscovery.scan(@files, SystemNetworkBus.new)
          data = Inventory.scan(@files, desktop: @desktop_name || DesktopEnvironment.detect(@files), connectivity: connectivity)
          drives = @drive_health_loader.try(&.call(data.drives)) || DriveHealthDiscovery.scan(data.drives, SystemNetworkBus.new)
          graphics = @graphics_loader.try(&.call(data.graphics)) || GraphicsDiagnostics.scan(data.graphics)
          monitors = @display_loader.try(&.call(data.monitors)) || DisplayConfig.enrich(data.monitors)
          results.send(data.copy_with(graphics: graphics, monitors: monitors, drives: drives))
        rescue error : Exception
          results.send(error)
        end
      end
      # GTK objects stay on the GTK main thread, including error handling. A
      # closed window stops polling; the bounded worker can finish independently.
      GLib.timeout(75.milliseconds) do
        if @closed
          false
        else
          select
          when result = results.receive
            @loading = false
            @refresh.enabled = true
            if result.is_a?(Snapshot)
              @snapshot = result
              render
            else
              clear_body
              status = Adw::StatusPage.new
              status.icon_name = "dialog-warning-symbolic"
              status.title = translate("Could not read system information")
              status.description = result.message || translate("Unknown")
              @body.append(status)
            end
            false
          else
            true
          end
        end
      end
    end

    private def clear_body
      while child = @body.first_child
        @body.remove(child)
      end
    end

    private def load_firmware
      return if @closed || @firmware_query || @firmware || !unlock_available?
      query = FirmwareQuery.new
      @firmware_query = query
      @firmware_action.enabled = false
      @firmware_message = ""
      render
      results = Channel(FirmwareResult).new(1)
      loader = @firmware_loader
      Fiber::ExecutionContext::Isolated.new("hardware-details") do
        begin
          results.send(loader ? loader.call : query.run)
        rescue error : Exception
          results.send(FirmwareResult.new)
        end
      end
      deadline = Time.instant + 120.seconds
      GLib.timeout(100.milliseconds) do
        if @closed
          false
        else
          select
          when result = results.receive
            @firmware = result.details if result.details
            @firmware_message = result.details ? "" : (result.cancelled ? translate("Authentication cancelled.") : translate("Hardware details could not be unlocked."))
            @firmware_query = nil
            render
            false
          else
            if Time.instant >= deadline
              query.cancel
              @firmware_query = nil
              @firmware_message = translate("Hardware details could not be unlocked.")
              render
              false
            else
              true
            end
          end
        end
      end
    end

    private def copy_snapshot(all : Bool)
      return unless data = @snapshot
      text = all ? SnapshotExport.full(data, @firmware) : SnapshotExport.overview(data)
      display.not_nil!.clipboard.set(text)
    end

    private def unlock_available? : Bool
      !@firmware_loader.nil? || FirmwareQuery.available?
    end

    private def update_unlock_banner
      @firmware_action.enabled = @firmware.nil? && @firmware_query.nil? && unlock_available?
      @unlock_banner.revealed = !@snapshot.nil? && @firmware.nil? && {"processor", "memory"}.includes?(@page)
      @unlock_banner.button_label = @firmware_query ? translate("Unlocking…") : translate("Unlock…")
      # Style the template button directly to also support libadwaita 1.5/1.6,
      # which do not have AdwBanner:button-style yet.
      Gtk::Button.g_type
      style_unlock_button(@unlock_banner)
    end

    private def style_unlock_button(widget : Gtk::Widget)
      widget.add_css_class("suggested-action") if widget.is_a?(Gtk::Button)
      child = widget.first_child
      while child
        style_unlock_button(child)
        child = child.next_sibling
      end
    end

    private def firmware_status
      unless @firmware_message.empty?
        status = Gtk::Label.new(@firmware_message)
        status.wrap = true
        status.xalign = 0.0
        @body.append(status)
      end
    end

    private def render
      update_unlock_banner
      @two_column_layouts.clear
      clear_body
      unless data = @snapshot
        loading = Adw::StatusPage.new
        loading.icon_name = "computer-symbolic"
        loading.title = translate("Reading system information…")
        @body.append(loading)
        return
      end
      case @page
      when "overview"  then overview(data)
      when "processor" then processor(data)
      when "mainboard" then mainboard(data)
      when "graphics"  then graphics(data)
      when "drives"    then drives(data)
      when "memory"    then memory(data)
      when "monitors"  then monitors(data)
      when "audio"     then audio(data)
      when "inputs"    then inputs(data)
      when "network"   then network(data)
      when "system"    then system(data)
      when "power"     then power(data)
      end
    end

    private def heading(title : String, description : String? = nil)
      box = Gtk::Box.new(:vertical, 6)
      label = Gtk::Label.new(title)
      label.xalign = 0.0
      label.wrap = true
      label.add_css_class("title-1")
      box.append(label)
      if description && !description.empty?
        detail = Gtk::Label.new(description)
        detail.xalign = 0.0
        detail.wrap = true
        detail.add_css_class("dim-label")
        box.append(detail)
      end
      @body.append(box)
    end

    private def group(title : String, parent : Gtk::Box | Gtk::FlowBox = @body) : Adw::PreferencesGroup
      widget = Adw::PreferencesGroup.new
      widget.title = title
      widget.width_request = 240 if parent.is_a?(Gtk::FlowBox)
      widget.valign = :start
      parent.append(widget)
      widget
    end

    private def group_columns(max_columns : UInt32 = 3) : Gtk::FlowBox
      columns = Gtk::FlowBox.new
      columns.selection_mode = :none
      columns.min_children_per_line = 1
      columns.max_children_per_line = max_columns
      columns.homogeneous = false
      columns.column_spacing = 24
      columns.row_spacing = 24
      @body.append(columns)
      columns
    end

    private def row(group : Adw::PreferencesGroup, title : String, value : String, icon : String? = nil, target : String? = nil, locked : Bool = false)
      widget = Adw::ActionRow.new
      widget.use_markup = false
      widget.title = title
      widget.subtitle = locked ? "" : (value.empty? ? translate("Unknown") : value)
      widget.sensitive = !locked
      widget.subtitle_selectable = true
      widget.add_prefix(Gtk::Image.new_from_icon_name(icon)) if icon
      target.try do |page|
        widget.activatable = true
        widget.focusable = true
        widget.subtitle_selectable = false
        arrow = Gtk::Image.new_from_icon_name("go-next-symbolic")
        arrow.valign = :center
        widget.add_suffix(arrow)
        widget.activated_signal.connect { navigate(page) }
      end
      group.add(widget)
    end

    private def navigate(page : String)
      index = 0
      while item = @navigation.row_at_index(index)
        if item.name == page
          @navigation.select_row(item)
          @split.show_sidebar = false if @split.collapsed?
          return
        end
        index += 1
      end
    end

    private def update_history_actions
      @back.enabled = @history_index > 0
      @forward.enabled = @history_index >= 0 && @history_index < @history.size - 1
    end

    private def move_history(direction : Int32)
      index = @history_index + direction
      return unless index >= 0 && index < @history.size
      @history_index = index
      @history_traversal = true
      begin
        navigate(@history[index])
      ensure
        @history_traversal = false
      end
      update_history_actions
    end

    private def count(value : Int32) : String
      value > 0 ? value.to_s : translate("Unknown")
    end

    private def capacity(bytes : UInt64, binary : Bool = false) : String
      bytes > 0 ? SystemView.format_bytes(bytes, binary) : translate("Unknown")
    end

    private def overview(data : Snapshot)
      hero = Gtk::Box.new(:vertical, 10)
      icon = Gtk::Image.new_from_icon_name(APP_ID)
      icon.pixel_size = 96
      hero.append(icon)
      title = Gtk::Label.new(data.hostname.empty? ? "System View" : data.hostname)
      title.add_css_class("title-1")
      title.wrap = true
      hero.append(title)
      subtitle = Gtk::Label.new(data.os)
      subtitle.wrap = true
      subtitle.justify = :center
      subtitle.add_css_class("dim-label")
      hero.append(subtitle)
      @body.append(hero)
      hardware = group(translate("Hardware summary"))
      cpu = data.processor
      cpu_info = [cpu.name, translate("%{cores} cores · %{threads} threads", cores: count(cpu.cores), threads: count(cpu.threads))].reject(&.empty?).join("\n")
      row(hardware, translate("Processor"), cpu_info, "system-view-processor-symbolic", target: "processor")
      row(hardware, translate("Mainboard"), [data.mainboard.vendor, data.mainboard.name].reject(&.empty?).join(" "), "system-view-mainboard-symbolic", target: "mainboard")
      graphics = data.graphics.map do |gpu|
        vendor = gpu.board_vendor.empty? ? gpu.vendor : gpu.board_vendor
        vendor = "ASUS" if vendor.starts_with?("ASUSTeK")
        [vendor.empty? ? translate("Unknown") : vendor, gpu.name, capacity(gpu.memory, binary: true)].join(" · ")
      end.join("\n")
      row(hardware, translate("Graphics"), graphics, "system-view-graphics-symbolic", target: "graphics")
      monitors = data.monitors.map do |monitor|
        [monitor.vendor, monitor.model, monitor.preferred_mode, monitor.connector].map { |value| value.empty? ? translate("Unknown") : value }.join(" · ")
      end.join("\n")
      row(hardware, translate("Monitors"), monitors, "video-display-symbolic", target: "monitors")
      memory_info = [Inventory.common_memory_model(data.memory), capacity(data.memory.installed, binary: true)].reject(&.empty?)
      kinds = data.memory.modules.map(&.kind).reject(&.empty?).uniq
      memory_info << kinds.join(" / ") unless kinds.empty?
      row(hardware, translate("Memory"), memory_info.join(" · "), "system-view-memory-symbolic", target: "memory")
      storage = data.drives.map { |drive| "#{drive.model} · #{capacity(drive.bytes)}" }.join("\n")
      row(hardware, translate("Storage"), storage, "drive-harddisk-symbolic", target: "drives")
      connections = data.connectivity.devices.map do |device|
        lan_ip = device.kind == "ethernet" ? device.ipv4.addresses.first?.try(&.split('/').first) || "" : ""
        [network_kind(device.kind), device.interface, network_state(device.state),
         device.ssid, device.speed_mbps > 0 ? link_speed(device.speed_mbps) : "", lan_ip].reject(&.empty?).join(" · ")
      end
      data.connectivity.bluetooth.each do |adapter|
        connections << [translate("Bluetooth"), adapter.name.presence || adapter.id, power_state(adapter.powered)].join(" · ")
      end
      row(hardware, translate("Network"), connections.empty? ? translate("None") : connections.join("\n"), "network-wired-symbolic", target: "network")
      software = group(translate("System"))
      row(software, translate("Operating System"), data.os, "preferences-system-symbolic", target: "system")
      row(software, translate("Kernel"), data.kernel, "system-view-processor-symbolic", target: "system")
      row(software, translate("Desktop Environment"), data.desktop, "preferences-desktop-display-symbolic", target: "system")
      row(software, translate("Uptime"), uptime_text(data.uptime), "preferences-system-time-symbolic", target: "system")
    end

    private def processor(data : Snapshot)
      heading(translate("Processor"), data.processor.name)
      firmware_status
      columns = group_columns
      details = group(translate("Identification"), columns)
      cpu = data.processor
      row(details, translate("Model"), cpu.name)
      row(details, translate("Manufacturer"), cpu.vendor)
      row(details, translate("Architecture"), cpu.architecture)
      row(details, translate("CPU family"), cpu.family)
      row(details, translate("Model ID"), cpu.model_id)
      row(details, translate("Stepping"), cpu.stepping)
      topology = group(translate("Topology and socket"), columns)
      row(topology, translate("Physical cores"), count(cpu.cores))
      row(topology, translate("Logical processors"), count(cpu.threads))
      row(topology, translate("Socket count"), count(cpu.sockets))
      processors = [] of FirmwareProcessor?
      if firmware = @firmware
        firmware.processors.each { |entry| processors << entry }
      end
      {cpu.sockets, 1}.max.times { processors << nil } if processors.empty?
      locked = @firmware.nil?
      if processors.size == 1
        entry = processors.first
        row(topology, translate("Socket"), entry.try(&.socket) || "", locked: locked)
        row(topology, translate("Socket type"), entry.try(&.upgrade) || "", locked: locked)
      else
        processors.each_with_index do |entry, index|
          socket = group(translate("Socket %{number}", number: index + 1), columns)
          row(socket, translate("Socket"), entry.try(&.socket) || "", locked: locked)
          row(socket, translate("Socket type"), entry.try(&.upgrade) || "", locked: locked)
        end
      end
      clocks = group(translate("Clock speed"), columns)
      speed = cpu.clocks
      row(clocks, translate("Base clock"), frequency(speed.base_khz))
      row(clocks, translate("Minimum clock"), frequency(speed.minimum_khz))
      row(clocks, translate("Maximum clock"), frequency(speed.maximum_khz))
      current = frequency(speed.current_min_khz)
      current += " – #{frequency(speed.current_max_khz)}" if speed.current_max_khz > speed.current_min_khz
      row(clocks, translate("Current clock range"), current)
      control = group(translate("Clock control"), columns)
      row(control, translate("Available frequency steps"), speed.steps_khz.map { |khz| frequency(khz) }.join(" · "))
      row(control, translate("Frequency driver"), speed.driver)
      row(control, translate("Governor"), speed.governor)
      boost = speed.boost.nil? ? translate("Unknown") : (speed.boost ? translate("Yes") : translate("No"))
      row(control, translate("Boost enabled"), boost)
      processors.each_with_index do |entry, index|
        extra_title = translate("Additional processor information")
        if processors.size > 1
          extra_title = translate("%{section} · Socket %{number}", section: extra_title, number: index + 1)
        end
        extra = group(extra_title, columns)
        row(extra, translate("Voltage"), entry.try(&.voltage) || "", locked: locked)
        row(extra, translate("External clock"), entry.try(&.external_clock) || "", locked: locked)
        row(extra, translate("Configured clock"), entry.try(&.configured_clock) || "", locked: locked)
        row(extra, translate("Maximum clock"), entry.try(&.maximum_clock) || "", locked: locked)
      end
      caches = group(translate("Caches"), columns)
      row(caches, translate("Cache information"), "") if cpu.caches.empty?
      cpu.caches.each do |cache|
        kind = case cache.kind
               when "Data"        then translate("Data")
               when "Instruction" then translate("Instructions")
               when "Unified"     then translate("Data and instructions")
               else                    cache.kind
               end
        title = translate("L%{level} cache (%{type})", level: cache.level, type: kind)
        total = cache.bytes <= UInt64::MAX // cache.instances ? capacity(cache.bytes * cache.instances, binary: true) : translate("Unknown")
        info = [translate("%{count} × %{size} · %{total} total", count: cache.instances,
          size: capacity(cache.bytes, binary: true), total: total)]
        info << translate("%{size} cache lines", size: capacity(cache.line_bytes, binary: true)) if cache.line_bytes > 0
        info << translate("%{ways}-way associative", ways: cache.ways) if cache.ways > 0
        row(caches, title, info.join("\n"))
      end
      processors.each_with_index do |entry, index|
        features_title = translate("Processor features")
        if processors.size > 1
          features_title = translate("%{section} · Socket %{number}", section: features_title, number: index + 1)
        end
        features = group(features_title, columns)
        row(features, translate("Processor Features"), entry.try { |processor| processor.capabilities.join("\n") } || "", locked: locked)
        row(features, translate("Characteristics"), entry.try { |processor| processor.characteristics.join("\n") } || "", locked: locked)
      end
    end

    private def frequency(khz : UInt64) : String
      return translate("Unknown") if khz == 0
      khz >= 1_000_000 ? "#{(khz / 1_000_000.0).round(2)} GHz" : "#{(khz / 1000.0).round(1)} MHz"
    end

    private def mainboard(data : Snapshot)
      heading(translate("Mainboard"), data.mainboard.name)
      board = data.mainboard
      columns = group_columns(2)
      details = group(translate("Identification"), columns)
      row(details, translate("Manufacturer"), board.vendor)
      row(details, translate("Model"), board.name)
      row(details, translate("Revision"), board.version)
      firmware = group(translate("Firmware"), columns)
      row(firmware, translate("BIOS vendor"), board.bios_vendor)
      row(firmware, translate("BIOS version"), board.bios_version)
      row(firmware, translate("BIOS date"), board.bios_date)
      security = group(translate("Boot and security"), columns)
      mode = case board.boot_mode
             when "uefi"   then "UEFI"
             when "legacy" then translate("Legacy BIOS")
             else               translate("Unknown")
             end
      row(security, translate("Boot mode"), mode)
      row(security, translate("Secure Boot"), power_state(board.secure_boot))
      tpm = if board.tpm_present.nil?
              translate("Unknown")
            elsif !board.tpm_present
              translate("Not detected")
            elsif board.tpm_versions.empty?
              translate("Detected")
            else
              board.tpm_versions.map { |version| "TPM #{version}" }.join(" · ")
            end
      row(security, translate("TPM"), tpm)
    end

    private def graphics(data : Snapshot)
      heading(translate("Graphics"))
      if data.graphics.empty?
        row(group(translate("Graphics")), translate("Display controller"), "")
      end
      data.graphics.each do |gpu|
        title = Gtk::Label.new(gpu.name)
        title.xalign = 0.0
        title.wrap = true
        title.add_css_class("heading")
        @body.append(title)
        columns = group_columns(2)
        columns.min_children_per_line = @split.collapsed? ? 1_u32 : 2_u32
        @two_column_layouts << columns
        details = group(translate("Identification"), columns)
        row(details, translate("GPU model"), gpu.model)
        row(details, translate("GPU manufacturer"), gpu.vendor)
        row(details, translate("Card manufacturer"), gpu.board_vendor)
        row(details, translate("Board model"), gpu.board_model)
        row(details, translate("Model group"), gpu.model_group)
        attached = data.monitors.select { |monitor| monitor.graphics_address == gpu.address }
        unless attached.empty?
          displays = attached.map do |monitor|
            [monitor_title(monitor), monitor.connector, monitor.current_mode,
             monitor.current_hz > 0 ? "#{monitor.current_hz.round(2)} Hz" : ""].reject(&.empty?).join(" · ")
          end
          row(details, translate("Connected monitors"), displays.join("\n"), target: "monitors")
        end
        details = group(translate("PCI and driver"), columns)
        row(details, translate("PCI ID"), "#{gpu.vendor_id}:#{gpu.device_id}")
        row(details, translate("Subsystem ID"), gpu.subsystem_id)
        row(details, translate("Revision"), gpu.revision)
        row(details, translate("PCI address"), gpu.address)
        row(details, translate("Kernel driver"), gpu.driver)
        details = group(translate("Memory and clocks"), columns)
        row(details, translate("Dedicated video memory"), capacity(gpu.memory, binary: true))
        row(details, translate("Current GPU clock"), gpu.clock_mhz > 0 ? "#{gpu.clock_mhz} MHz" : translate("Not reported"))
        row(details, translate("Current video memory clock"), gpu.memory_clock_mhz > 0 ? "#{gpu.memory_clock_mhz} MHz" : translate("Not reported"))
        details = group(translate("Graphics APIs"), columns)
        row(details, translate("OpenGL"), gpu.opengl.empty? ? translate("Not reported") : gpu.opengl)
        row(details, translate("GLSL"), gpu.glsl.empty? ? translate("Not reported") : gpu.glsl)
        row(details, translate("OpenGL ES"), gpu.opengl_es.empty? ? translate("Not reported") : gpu.opengl_es)
        row(details, translate("OpenGL renderer"), gpu.renderer) unless gpu.renderer.empty?
        row(details, translate("Vulkan"), gpu.vulkan.empty? ? translate("Not reported") : gpu.vulkan)
        row(details, translate("Vulkan driver"), gpu.vulkan_driver) unless gpu.vulkan_driver.empty?
      end
    end

    private def drives(data : Snapshot)
      heading(translate("Drives"))
      if data.drives.empty?
        row(group(translate("Storage")), translate("Drives"), "")
      end
      data.drives.each do |drive|
        title = Gtk::Label.new(drive.model)
        title.xalign = 0.0
        title.wrap = true
        title.add_css_class("heading")
        @body.append(title)
        columns = group_columns
        identification = group("", columns)
        row(identification, translate("Model"), drive.model)
        row(identification, translate("Manufacturer"), drive.vendor)
        properties = group("", columns)
        row(properties, translate("Capacity"), capacity(drive.bytes))
        row(properties, translate("Type"), drive.kind)
        connection = group("", columns)
        row(connection, translate("Connection"), drive.connection)
        row(connection, translate("Device"), "/dev/#{drive.name}")
        row(connection, translate("Removable"), drive.removable ? translate("Yes") : translate("No"))
        health = group("", columns)
        status = drive.health.failing.nil? ? translate("Not reported") : (drive.health.failing ? translate("Warning") : translate("OK"))
        row(health, translate("Status (SMART)"), status)
        row(health, translate("Temperature"), drive.health.temperature.try { |value| "#{value.round(1)} °C" } || translate("Not reported"))
        row(health, translate("Power-on hours"), drive.health.power_on_hours.try(&.to_s) || translate("Not reported"))
        row(health, translate("Last updated"), DriveHealthDiscovery.updated_text(drive.health.updated_at).presence || translate("Not reported"))
      end
    end

    private def memory(data : Snapshot)
      heading(translate("Memory"))
      firmware_status
      columns = group_columns
      details = group(translate("Memory"), columns)
      row(details, translate("Installed RAM"), capacity(data.memory.installed, binary: true))
      row(details, translate("Usable RAM"), capacity(data.memory.total, binary: true))
      row(details, translate("Available RAM"), capacity(data.memory.available, binary: true))
      row(details, translate("Swap"), data.memory.swap == 0 ? translate("None") : capacity(data.memory.swap, binary: true))
      unless data.memory.modules.empty?
        data.memory.modules.each_with_index do |mod, index|
          title = mod.slot.empty? ? translate("Module %{number}", number: index + 1) : mod.slot
          details = group(title, columns)
          info = [capacity(mod.bytes, binary: true)]
          info << mod.kind unless mod.kind.empty?
          info << "#{mod.speed_mts} MT/s" if mod.speed_mts > 0
          voltage = mod.voltage > 0 && mod.voltage.finite? ? "#{mod.voltage} V" : ""
          minimum = mod.minimum_voltage > 0 && mod.minimum_voltage.finite? ? "#{mod.minimum_voltage} V" : ""
          maximum = mod.maximum_voltage > 0 && mod.maximum_voltage.finite? ? "#{mod.maximum_voltage} V" : ""
          part = mod.part_number
          manufacturer = mod.manufacturer
          if firmware = @firmware
            matching = firmware.memory.select { |entry| [entry.bank, entry.slot].reject(&.empty?).join(" · ") == mod.slot }
            if matching.size == 1
              voltage = matching.first.voltage unless matching.first.voltage.empty?
              minimum = matching.first.minimum_voltage unless matching.first.minimum_voltage.empty?
              maximum = matching.first.maximum_voltage unless matching.first.maximum_voltage.empty?
              part = matching.first.part_number unless matching.first.part_number.empty?
              manufacturer = matching.first.manufacturer unless matching.first.manufacturer.empty?
            end
          end
          identity = RamIdentifiers.identify(part, manufacturer)
          brand = [identity.manufacturer, identity.series].reject(&.empty?).join(" ")
          model = [brand, part].reject(&.empty?).join(" · ")
          value = [model, info.join(" · ")].reject(&.empty?).join("\n")
          row(details, translate("Model"), value)
          row(details, translate("Timings (CL–tRCD–tRP–tRAS)"), translate("Not reported"))
          row(details, translate("Voltage"), voltage, locked: @firmware.nil?)
          row(details, translate("Minimum voltage"), minimum, locked: @firmware.nil?)
          row(details, translate("Maximum voltage"), maximum, locked: @firmware.nil?)
        end
      end
    end

    private def system(data : Snapshot)
      heading(translate("Operating System"), data.os)
      details = group(translate("System"))
      row(details, translate("Operating System"), data.os)
      row(details, translate("Kernel"), data.kernel)
      row(details, translate("Desktop Environment"), data.desktop)
      row(details, translate("Hostname"), data.hostname)
      row(details, translate("Uptime"), uptime_text(data.uptime))
    end

    private def power(data : Snapshot)
      heading(translate("Power"))
      supply = data.power_supply
      if supply.batteries.empty? && supply.adapters.empty?
        row(group(translate("Power")), translate("Power information"), translate("Not reported"))
      end
      columns = group_columns(2)
      supply.adapters.each do |adapter|
        details = group(translate("Power adapter") + " · " + adapter.name, columns)
        row(details, translate("Connected"), enabled(adapter.online))
      end
      supply.batteries.each do |battery|
        details = group(translate("Battery") + " · " + battery.name, columns)
        row(details, translate("Manufacturer"), battery.vendor) unless battery.vendor.empty?
        row(details, translate("Model"), battery.model) unless battery.model.empty?
        status = case battery.status
                 when "Charging"     then translate("Charging")
                 when "Discharging"  then translate("Discharging")
                 when "Full"         then translate("Fully charged")
                 when "Not charging" then translate("Not charging")
                 else                     translate("Unknown")
                 end
        row(details, translate("Status"), status)
        row(details, translate("Charge"), battery.percent.try { |value| "#{value.round(1)} %" } || translate("Not reported"))
        row(details, translate("Full charge capacity"), battery.full.try { |value| "#{value.round(2)} #{battery.unit}" } || translate("Not reported"))
        row(details, translate("Design capacity"), battery.design.try { |value| "#{value.round(2)} #{battery.unit}" } || translate("Not reported"))
        health = if (full = battery.full) && (design = battery.design) && design > 0
                   "#{(full / design * 100).round(1)} %"
                 else
                   translate("Not reported")
                 end
        row(details, translate("Battery health"), health)
        row(details, translate("Charge cycles"), battery.cycles.try(&.to_s) || translate("Not reported"))
        row(details, translate("Battery power"), battery.power.try { |value| "#{value.round(2)} W" } || translate("Not reported"))
        remaining = battery.remaining_seconds.try { |seconds| seconds == 0 ? translate("0 min") : uptime_text(seconds.to_f64) } || translate("Not reported")
        label = battery.status == "Charging" ? translate("Estimated time to full") : translate("Estimated time remaining")
        row(details, label, remaining)
      end
    end

    private def monitors(data : Snapshot)
      heading(translate("Monitors"))
      row(group(translate("Monitors")), translate("Monitor"), "") if data.monitors.empty?
      data.monitors.each_with_index do |monitor, index|
        columns = group_columns(2)
        columns.min_children_per_line = @split.collapsed? ? 1_u32 : 2_u32
        @two_column_layouts << columns
        details = group(monitor_title(monitor, index + 1), columns)
        row(details, translate("Manufacturer"), monitor.vendor)
        row(details, translate("Model"), monitor.model)
        row(details, translate("Product ID"), monitor.product_id)
        row(details, translate("Connection"), monitor.connector)
        row(details, translate("Active"), monitor.active ? translate("Yes") : translate("No"))
        details = group("", columns)
        row(details, translate("Current resolution"), monitor.current_mode.empty? ? translate("Not reported") : monitor.current_mode)
        row(details, translate("Current refresh rate"), monitor.current_hz > 0 ? "#{monitor.current_hz.round(2)} Hz" : translate("Not reported"))
        row(details, translate("Preferred resolution"), monitor.preferred_mode)
        row(details, translate("Preferred refresh rate"), monitor.preferred_hz > 0 ? "#{monitor.preferred_hz.round(2)} Hz" : "")
        details = group("", columns)
        if monitor.width_mm > 0 && monitor.height_mm > 0
          row(details, translate("Display size"), "#{monitor.width_mm} × #{monitor.height_mm} mm")
          diagonal = Math.sqrt(monitor.width_mm.to_f64 ** 2 + monitor.height_mm.to_f64 ** 2) / 25.4
          row(details, translate("Diagonal"), "#{diagonal.round(1)}″")
        end
        row(details, translate("Supported resolutions"), monitor.modes.join(" · "))
      end
    end

    private def monitor_title(monitor : Monitor, fallback : Int32 = 1) : String
      title = translate("Monitor %{number}", number: monitor.number > 0 ? monitor.number : fallback)
      primary = translate("Primary")
      monitor.primary == true ? "#{title} (#{primary})" : title
    end

    private def audio(data : Snapshot)
      heading(translate("Audio"))
      row(group(translate("Audio")), translate("Audio device"), "") if data.audio.empty?
      data.audio.each do |device|
        title = Gtk::Label.new(device.name)
        title.xalign = 0.0
        title.wrap = true
        title.add_css_class("heading")
        @body.append(title)
        columns = group_columns
        details = group("", columns)
        row(details, translate("Name"), device.name)
        row(details, translate("Device ID"), device.id)
        details = group("", columns)
        row(details, translate("Driver"), device.driver)
        details = group("", columns)
        row(details, translate("Codecs"), device.codecs.join("\n"))
      end
    end

    private def inputs(data : Snapshot)
      heading(translate("Input Devices"))
      row(group(translate("Input Devices")), translate("Input device"), "") if data.inputs.empty?
      data.inputs.each do |device|
        title = Gtk::Label.new(device.name)
        title.xalign = 0.0
        title.wrap = true
        title.add_css_class("heading")
        @body.append(title)
        columns = group_columns(2)
        details = group("", columns)
        kind = case device.kind
               when "keyboard"    then translate("Keyboard")
               when "mouse"       then translate("Mouse")
               when "gamepad"     then translate("Gamepad / Joystick")
               when "touchpad"    then translate("Touchpad")
               when "touchscreen" then translate("Touchscreen")
               when "tablet"      then translate("Graphics tablet")
               else                    translate("Input device")
               end
        row(details, translate("Type"), kind)
        row(details, translate("Connection"), device.bus)
        details = group("", columns)
        row(details, translate("Vendor ID"), device.vendor_id)
        row(details, translate("Product ID"), device.product_id)
      end
    end

    private def network(data : Snapshot)
      heading(translate("Network"))
      if data.connectivity.devices.empty? && data.connectivity.bluetooth.empty?
        row(group(translate("Network")), translate("Network adapters"), translate("None"))
      end
      data.connectivity.devices.each do |device|
        columns = group_columns
        columns.homogeneous = true
        details = group("#{network_kind(device.kind)} · #{device.interface}", columns)
        row(details, translate("Model"), device.name) unless device.name.empty?
        row(details, translate("Interface"), device.interface)
        row(details, translate("Status"), network_state(device.state))
        row(details, translate("Connection profile"), device.connection) unless device.connection.empty?
        row(details, translate("Link speed"), link_speed(device.speed_mbps))
        unless device.duplex.empty? || device.duplex == "unknown"
          row(details, translate("Duplex"), device.duplex == "full" ? translate("Full duplex") : (device.duplex == "half" ? translate("Half duplex") : device.duplex))
        end
        row(details, translate("MAC address"), device.mac)
        row(details, translate("Permanent MAC address"), device.permanent_mac) unless device.permanent_mac.empty?
        row(details, translate("MTU"), device.mtu > 0 ? "#{device.mtu} B" : "")
        row(details, translate("Kernel driver"), device.driver)
        if device.kind == "wifi"
          row(details, translate("SSID"), device.ssid)
          row(details, translate("Access point (BSSID)"), device.bssid)
          row(details, translate("Signal strength"), device.signal.try { |signal| "#{signal}%" } || "")
          row(details, translate("Frequency"), device.frequency_mhz > 0 ? "#{device.frequency_mhz} MHz" : "")
          row(details, translate("Security"), device.security == "open" ? translate("Open network") : device.security)
        end
        network_addresses(device.interface, device.ipv4, 4, columns)
        network_addresses(device.interface, device.ipv6, 6, columns)
      end
      data.connectivity.bluetooth.each do |adapter|
        columns = group_columns
        columns.homogeneous = true
        details = group("#{translate("Bluetooth")} · #{adapter.id}", columns)
        row(details, translate("Name"), adapter.name)
        row(details, translate("MAC address"), adapter.address)
        row(details, translate("Enabled"), enabled(adapter.powered))
        row(details, translate("Bluetooth version"), adapter.version)
        row(details, translate("Link speed"), translate("Not reported"))
        row(details, translate("Discoverable"), enabled(adapter.discoverable))
        row(details, translate("Pairable"), enabled(adapter.pairable))
        row(details, translate("Kernel driver"), adapter.driver) unless adapter.driver.empty?
        row(details, translate("Connected devices"), adapter.devices.count(&.connected).to_s)
        adapter.devices.each do |device|
          remote = group("#{translate("Bluetooth")} · #{device.name.presence || device.address}", columns)
          row(remote, translate("MAC address"), device.address)
          row(remote, translate("Connected"), enabled(device.connected))
          row(remote, translate("Paired"), enabled(device.paired))
          row(remote, translate("Signal strength"), "#{device.rssi} dBm") if device.connected && device.rssi
        end
      end
    end

    private def network_addresses(interface : String, config : NetworkAddress, version : Int32, columns : Gtk::FlowBox)
      details = group("#{interface} · IPv#{version}", columns)
      missing = config.available ? translate("None") : translate("Unknown")
      row(details, translate("IP addresses"), config.addresses.empty? ? missing : config.addresses.join("\n"))
      row(details, translate("Address configuration"), address_method(config.method))
      row(details, translate("DHCP"), enabled(config.dhcp))
      row(details, translate("Gateway"), config.gateway.empty? ? missing : config.gateway)
      row(details, translate("DNS servers"), config.dns.empty? ? missing : config.dns.join("\n"))
      row(details, translate("Search domains"), config.domains.join("\n")) unless config.domains.empty?
    end

    private def enabled(value : Bool?) : String
      value.nil? ? translate("Unknown") : (value ? translate("Yes") : translate("No"))
    end

    private def power_state(value : Bool?) : String
      value.nil? ? translate("Unknown") : (value ? translate("Active") : translate("Inactive"))
    end

    private def uptime_text(seconds : Float64) : String
      return translate("Unknown") unless seconds > 0
      total = seconds.to_i
      days = total // 86_400
      hours = (total % 86_400) // 3_600
      minutes = (total % 3_600) // 60
      if days > 0
        translate("%{days} d %{hours} h %{minutes} min", days: days, hours: hours, minutes: minutes)
      elsif hours > 0
        translate("%{hours} h %{minutes} min", hours: hours, minutes: minutes)
      else
        translate("%{minutes} min", minutes: minutes)
      end
    end

    private def network_kind(kind : String) : String
      case kind
      when "wifi"      then translate("Wi-Fi")
      when "bluetooth" then translate("Bluetooth PAN")
      else                  translate("Ethernet (LAN)")
      end
    end

    private def network_state(state : String) : String
      case state
      when "connected"     then translate("Connected")
      when "disconnected"  then translate("Disconnected")
      when "connecting"    then translate("Connecting")
      when "disconnecting" then translate("Disconnecting")
      when "unavailable"   then translate("Unavailable")
      when "unmanaged"     then translate("Unmanaged")
      when "failed"        then translate("Connection failed")
      else                      translate("Unknown")
      end
    end

    private def address_method(method : String) : String
      case method
      when "auto"       then translate("Automatic")
      when "manual"     then translate("Manual")
      when "dhcp"       then translate("DHCP")
      when "link-local" then translate("Link-local")
      when "shared"     then translate("Shared")
      when "disabled"   then translate("Disabled")
      when "ignore"     then translate("Ignored")
      else                   translate("Unknown")
      end
    end

    private def link_speed(mbps : Float64) : String
      return translate("Unknown") unless mbps > 0
      mbps >= 1000 ? "#{(mbps / 1000).round(2)} Gbit/s" : "#{mbps.round(1)} Mbit/s"
    end
  end
end
