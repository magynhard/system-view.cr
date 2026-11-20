require "gi-crystal/gio"

lib LibGio
  fun g_desktop_app_info_new(desktop_id : UInt8*) : Void*
end

module SystemView::DiskViewLauncher
  extend self

  DESKTOP_ID         = "de.magynhard.DiskView.desktop"
  PATH_VARIABLES     = %w[PATH LD_LIBRARY_PATH XDG_DATA_DIRS XDG_CONFIG_DIRS GI_TYPELIB_PATH GTK_PATH GIO_EXTRA_MODULES]
  APPIMAGE_VARIABLES = %w[APPDIR APPIMAGE APPIMAGE_EXTRACT_AND_RUN ARGV0 OWD]
  RESOURCE_VARIABLES = %w[GTK_DATA_PREFIX GTK_EXE_PREFIX GSETTINGS_SCHEMA_DIR GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR GIO_MODULE_DIR]

  def available? : Bool
    !app_info.nil?
  end

  def launch : Nil
    app_info.try(&.launch(nil, launch_context))
  rescue GLib::Error
    nil
  end

  def launch_context : Gio::AppLaunchContext
    context = Gio::AppLaunchContext.new
    return context unless appdir = ENV["APPDIR"]?

    inside_appdir = ->(path : String) { path == appdir || path.starts_with?("#{appdir}/") }
    PATH_VARIABLES.each do |name|
      if value = ENV[name]?
        paths = value.split(':').reject { |path| inside_appdir.call(path) }
        paths.empty? ? context.unsetenv(name) : context.setenv(name, paths.join(':'))
      end
    end
    %w[LD_PRELOAD LD_AUDIT].each do |name|
      if value = ENV[name]?
        paths = value.split(/[:\s]+/).reject { |path| inside_appdir.call(path) }
        paths.empty? ? context.unsetenv(name) : context.setenv(name, paths.join(':'))
      end
    end
    RESOURCE_VARIABLES.each do |name|
      context.unsetenv(name) if (value = ENV[name]?) && inside_appdir.call(value)
    end
    APPIMAGE_VARIABLES.each { |name| context.unsetenv(name) }
    context
  end

  private def app_info : Gio::AbstractAppInfo?
    pointer = LibGio.g_desktop_app_info_new(DESKTOP_ID)
    Gio::AbstractAppInfo.new(pointer, GICrystal::Transfer::Full) unless pointer.null?
  end
end
