require "gi-crystal/gio"

lib LibGio
  fun g_desktop_app_info_new(desktop_id : UInt8*) : Void*
  fun g_desktop_app_info_get_filename(info : Void*) : UInt8*
end

module SystemView::DiskViewLauncher
  extend self

  DESKTOP_ID         = "de.magynhard.DiskView.desktop"
  PATH_VARIABLES     = %w[PATH LD_LIBRARY_PATH XDG_DATA_DIRS XDG_CONFIG_DIRS GI_TYPELIB_PATH GTK_PATH GIO_EXTRA_MODULES]
  APPIMAGE_VARIABLES = %w[APPDIR APPIMAGE APPIMAGE_EXTRACT_AND_RUN ARGV0 OWD]
  RESOURCE_VARIABLES = %w[GTK_DATA_PREFIX GTK_EXE_PREFIX GSETTINGS_SCHEMA_DIR GDK_PIXBUF_MODULE_FILE GDK_PIXBUF_MODULEDIR GIO_MODULE_DIR]

  def desktop_file(sandboxed : Bool = File.file?("/.flatpak-info")) : String?
    if sandboxed
      host_desktop_file(ENV["HOME"]? || "", ENV["XDG_DATA_DIRS"]? || "")
    else
      pointer = LibGio.g_desktop_app_info_new(DESKTOP_ID)
      return nil if pointer.null?
      begin
        filename = LibGio.g_desktop_app_info_get_filename(pointer)
        String.new(filename) unless filename.null?
      ensure
        LibGObject.g_object_unref(pointer)
      end
    end
  end

  def host_desktop_file(home : String, data_dirs : String, host_root : String = "/run/host/root") : String?
    directories = [] of String
    unless home.empty?
      directories << "#{home}/.local/share"
      directories << "#{home}/.local/share/flatpak/exports/share"
    end
    directories.concat(data_dirs.split(':'))
    directories.concat(["/var/lib/flatpak/exports/share", "/usr/local/share", "/usr/share"])
    directories.select(&.starts_with?('/')).each do |directory|
      path = File.join(directory, "applications", DESKTOP_ID)
      return path if File.file?(File.join(host_root, path.lchop('/')))
    end
    nil
  end

  def available? : Bool
    !desktop_file.nil?
  end

  def launch : Nil
    sandboxed = File.file?("/.flatpak-info")
    return unless desktop = desktop_file(sandboxed)
    arguments = sandboxed ? ["flatpak-spawn", "--host", "gio", "launch", desktop] : ["gio", "launch", desktop]
    launcher = Gio::SubprocessLauncher.new(Gio::SubprocessFlags::StdoutSilence | Gio::SubprocessFlags::StderrSilence)
    clean_appimage_environment(launcher)
    # The generated spawnv wrapper does not append the required NULL sentinel.
    argv = arguments.map(&.to_unsafe) << Pointer(UInt8).null
    error = Pointer(LibGLib::Error).null
    process = LibGio.g_subprocess_launcher_spawnv(launcher, argv.to_unsafe, pointerof(error))
    GLib.raise_gerror(error) unless error.null?
    LibGObject.g_object_unref(process) unless process.null?
  rescue GLib::Error
    nil
  end

  def clean_appimage_environment(launcher : Gio::SubprocessLauncher) : Nil
    return unless appdir = ENV["APPDIR"]?

    inside_appdir = ->(path : String) { path == appdir || path.starts_with?("#{appdir}/") }
    (PATH_VARIABLES + %w[LD_PRELOAD LD_AUDIT]).each do |name|
      if value = ENV[name]?
        paths = (name.starts_with?("LD_PRELOAD") || name == "LD_AUDIT" ? value.split(/[:\s]+/) : value.split(':')).reject { |path| inside_appdir.call(path) }
        paths.empty? ? launcher.unsetenv(name) : launcher.setenv(name, paths.join(':'), true)
      end
    end
    RESOURCE_VARIABLES.each do |name|
      launcher.unsetenv(name) if (value = ENV[name]?) && inside_appdir.call(value)
    end
    APPIMAGE_VARIABLES.each { |name| launcher.unsetenv(name) }
  end
end
