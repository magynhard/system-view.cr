require "libadwaita"
require "./i18n"
require "./metadata"
require "./inventory"
require "./window"

module SystemView
  class App < Adw::Application
    def initialize(@window_factory : Proc(Window)? = nil)
      I18n.setup
      super(application_id: APP_ID, flags: Gio::ApplicationFlags::NonUnique)
      RESOURCE._register
      activate_signal.connect { activate_window }
    end

    # Allows deterministic startup smoke tests without substituting a generic GTK app.
    def window_factory=(factory : Proc(Window))
      @window_factory = factory
    end

    private def activate_window
      I18n.bind_toolkit_domains
      Gtk::IconTheme.for_display(Gdk::Display.default.not_nil!).add_resource_path("/de/magynhard/SystemView/icons")
      Gtk::Window.default_icon_name = APP_ID
      (active_window || @window_factory.try(&.call) || Window.new(self)).present
    end
  end
end
