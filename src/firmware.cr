require "./subprocess_output"

module SystemView
  record FirmwareProcessor, socket : String, voltage : String, external_clock : String,
    maximum_clock : String, configured_clock : String, upgrade : String,
    capabilities : Array(String), characteristics : Array(String)
  record FirmwareMemory, slot : String, bank : String, voltage : String,
    minimum_voltage : String, maximum_voltage : String, manufacturer : String = "", part_number : String = ""
  record FirmwareDetails, processors : Array(FirmwareProcessor), memory : Array(FirmwareMemory)
  record FirmwareResult, details : FirmwareDetails? = nil, cancelled : Bool = false

  module Firmware
    extend self

    def parse(text : String) : FirmwareDetails
      processors = [] of FirmwareProcessor
      memory = [] of FirmwareMemory
      text.split(/\n(?=Handle )/).each do |block|
        type = block.match(/DMI type (\d+),/).try(&.[1])
        next unless type == "4" || type == "17"
        fields = {} of String => String
        lists = {} of String => Array(String)
        list = ""
        block.lines.each do |line|
          if line.starts_with?("\t\t") && !list.empty?
            (lists[list] ||= [] of String) << line.strip
          elsif line.starts_with?("\t") && (pair = line.strip.split(':', 2)).size == 2
            key, value = pair[0], pair[1].strip
            fields[key] = {"Unknown", "Not Provided", "Not Specified"}.includes?(value) ? "" : value
            list = value.empty? ? key : ""
          end
        end
        if type == "4"
          processors << FirmwareProcessor.new(fields["Socket Designation"]? || "", fields["Voltage"]? || "",
            fields["External Clock"]? || "", fields["Max Speed"]? || "", fields["Current Speed"]? || "",
            fields["Upgrade"]? || "", lists["Flags"]? || [] of String, lists["Characteristics"]? || [] of String)
        elsif fields["Size"]? != "No Module Installed"
          memory << FirmwareMemory.new(fields["Locator"]? || "", fields["Bank Locator"]? || "",
            fields["Configured Voltage"]? || "", fields["Minimum Voltage"]? || "", fields["Maximum Voltage"]? || "",
            fields["Manufacturer"]? || "", fields["Part Number"]? || "")
        end
      end
      FirmwareDetails.new(processors, memory)
    end
  end

  # The UI stays unprivileged. Only the fixed read-only dmidecode invocation is
  # authorized through the desktop polkit agent; no shell or user arguments.
  class FirmwareQuery
    DMI_ARGUMENTS = {"--type", "4,17"}
    @mutex = Thread::Mutex.new
    @process : Gio::Subprocess?
    @cancellable = Gio::Cancellable.new
    @cancelled = false

    def self.decoder : String?
      return nil if OptionalToolSimulation.enabled?
      {"/usr/sbin/dmidecode", "/usr/bin/dmidecode", "/sbin/dmidecode", "/run/current-system/sw/bin/dmidecode", "/run/current-system/sw/sbin/dmidecode"}.find { |path| File.file?(path) && File::Info.executable?(path) }
    end

    def self.pkexec : String?
      return nil if OptionalToolSimulation.enabled?
      {"/usr/bin/pkexec", "/run/wrappers/bin/pkexec"}.find { |path| File.file?(path) && File::Info.executable?(path) }
    end

    def self.available? : Bool
      !File.file?("/.flatpak-info") && !pkexec.nil? && !decoder.nil?
    end

    def run : FirmwareResult
      decoder = self.class.decoder
      pkexec = self.class.pkexec
      return FirmwareResult.new unless decoder && pkexec && self.class.available?
      process = @mutex.synchronize do
        return FirmwareResult.new(cancelled: true) if @cancelled
        @process = SubprocessOutput.launch([pkexec, "--disable-internal-agent", decoder] + DMI_ARGUMENTS.to_a,
          {"LC_ALL" => "C", "LANG" => "C"})
      end
      output = SubprocessOutput.read(process, @cancellable)
      return FirmwareResult.new(cancelled: true) if @mutex.synchronize { @cancelled } || (process.if_exited && process.exit_status == 126)
      return FirmwareResult.new unless process.successful
      details = Firmware.parse(output)
      details.processors.empty? && details.memory.empty? ? FirmwareResult.new : FirmwareResult.new(details: details)
    rescue IO::Error | GLib::Error
      FirmwareResult.new(cancelled: @mutex.synchronize { @cancelled })
    ensure
      @mutex.synchronize { @process = nil }
    end

    def cancel
      @mutex.synchronize do
        @cancelled = true
        @cancellable.cancel
        @process.try(&.force_exit)
      end
    end
  end
end
