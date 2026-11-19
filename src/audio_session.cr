require "json"
require "./subprocess_output"

module SystemView::AudioSessionDiscovery
  extend self
  alias Runner = Proc(Array(String), String)

  def scan(runner : Runner = ->run(Array(String))) : AudioSession
    info = JSON.parse(runner.call(["info"])).as_h?
    return AudioSession.new unless info
    output = info["default_sink_name"]?.try(&.as_s?) || ""
    input = info["default_source_name"]?.try(&.as_s?) || ""
    AudioSession.new(server: info["server_name"]?.try(&.as_s?) || "",
      output: output.empty? ? "" : description(runner.call(["list", "sinks"]), output),
      input: input.empty? ? "" : description(runner.call(["list", "sources"]), input))
  rescue JSON::ParseException
    AudioSession.new
  end

  def description(text : String, name : String) : String
    devices = JSON.parse(text).as_a?
    device = devices.try(&.find { |item| item.as_h?.try(&.["name"]?).try(&.as_s?) == name })
    device.try(&.as_h?).try(&.["description"]?).try(&.as_s?).presence || name
  rescue JSON::ParseException
    name
  end

  private def run(arguments : Array(String)) : String
    return "" if OptionalToolSimulation.enabled?
    executable = Process.find_executable("pactl")
    timeout = Process.find_executable("timeout")
    return "" unless executable && timeout
    process = SubprocessOutput.launch([timeout, "--signal=TERM", "--kill-after=0.2s", "2s", executable, "--format=json"] + arguments,
      {"LC_ALL" => "C", "LANG" => "C"})
    output = SubprocessOutput.read(process)
    process.successful ? output : ""
  rescue IO::Error | GLib::Error
    ""
  end
end
