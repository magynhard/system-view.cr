require "json"
require "c/dlfcn"
require "./subprocess_output"

lib LibSystemViewCups
  struct Destination
    name : UInt8*
    instance : UInt8*
    is_default : Int32
    num_options : Int32
    options : Void*
  end
end

module SystemView
  record Printers, names : Array(String) = [] of String, available : Bool = false

  module PrinterDiscovery
    extend self
    alias Runner = Proc(String?)
    HELPER_ARGUMENT = "--system-view-list-printers"

    def scan(runner : Runner = ->run) : Printers
      output = runner.call
      return Printers.new unless output
      names = Array(String).from_json(output)
      Printers.new(names: names.uniq.sort, available: true)
    rescue JSON::ParseException
      Printers.new
    end

    # This runs only in the bounded child process, never in the GTK process.
    def cups_names : Array(String)?
      return nil if OptionalToolSimulation.enabled?
      library = LibC.dlopen("libcups.so.2", LibC::RTLD_LAZY)
      return nil if library.null?
      get_ptr = LibC.dlsym(library, "cupsGetDests")
      free_ptr = LibC.dlsym(library, "cupsFreeDests")
      error_ptr = LibC.dlsym(library, "cupsLastError")
      return nil if get_ptr.null? || free_ptr.null? || error_ptr.null?
      get = Proc(Pointer(Pointer(LibSystemViewCups::Destination)), Int32).new(get_ptr, Pointer(Void).null)
      free = Proc(Int32, Pointer(LibSystemViewCups::Destination), Nil).new(free_ptr, Pointer(Void).null)
      last_error = Proc(Int32).new(error_ptr, Pointer(Void).null)
      destinations = Pointer(LibSystemViewCups::Destination).null
      count = get.call(pointerof(destinations))
      begin
        status = last_error.call
        return nil if count == 0 && status >= 0x400 && status != 0x406
        (0...count).compact_map do |index|
          dest = destinations[index]
          String.new(dest.name).scrub unless dest.name.null? || !dest.instance.null?
        end
      ensure
        free.call(count, destinations)
      end
    ensure
      LibC.dlclose(library) if library && !library.null?
    end

    private def run : String?
      return nil if OptionalToolSimulation.enabled?
      executable = Process.executable_path
      timeout = Process.find_executable("timeout")
      return nil unless executable && timeout
      process = SubprocessOutput.launch([timeout, "--signal=TERM", "--kill-after=0.2s", "3s", executable, HELPER_ARGUMENT],
        {"LC_ALL" => "C", "LANG" => "C"})
      output = SubprocessOutput.read(process)
      process.successful ? output : nil
    rescue IO::Error | GLib::Error
      nil
    end
  end
end
