require "gi-crystal/gio"

module SystemView::SubprocessOutput
  extend self

  def launch(arguments : Array(String), environment : Hash(String, String) = {} of String => String) : Gio::Subprocess
    launcher = Gio::SubprocessLauncher.new(Gio::SubprocessFlags::StdoutPipe | Gio::SubprocessFlags::StderrSilence)
    environment.each { |name, value| launcher.setenv(name, value, true) }
    launcher.spawnv(arguments)
  end

  # Process.run with an IO::Memory output spawns Crystal copy fibers on the
  # default scheduler, which is occupied by GTK's native main loop. GIO drains
  # stdout and waits for the child without relying on that scheduler.
  def read(process : Gio::Subprocess, cancellable : Gio::Cancellable? = nil) : String
    output = Pointer(Void).null
    error = Pointer(LibGLib::Error).null
    begin
      success = LibGio.g_subprocess_communicate(process, Pointer(Void).null,
        cancellable.try(&.to_unsafe) || Pointer(Void).null,
        pointerof(output), Pointer(Pointer(Void)).null, pointerof(error))
      GLib.raise_gerror(error) unless error.null?
      return "" if success == 0 || output.null?
      length = 0_u64
      bytes = LibGLib.g_bytes_get_data(output, pointerof(length))
      String.new(bytes.as(UInt8*), length.to_i).scrub
    ensure
      LibGLib.g_bytes_unref(output) unless output.null?
    end
  end
end
