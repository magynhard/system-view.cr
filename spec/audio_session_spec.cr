require "spec"
require "./support/fixture_files"
require "../src/audio_session"

describe SystemView::AudioSessionDiscovery do
  it "identifies the default devices and server from the audio session" do
    runner = ->(arguments : Array(String)) do
      case arguments
      when ["info"]          then %({"server_name":"PulseAudio (on PipeWire 1.2)","default_sink_name":"sink.1","default_source_name":"source.1"})
      when ["list", "sinks"] then %([{"name":"sink.0","description":"Other"},{"name":"sink.1","description":"Speakers"}])
      else                        %([{"name":"source.1","description":"Microphone"}])
      end
    end
    session = SystemView::AudioSessionDiscovery.scan(runner)
    session.server.should eq("PulseAudio (on PipeWire 1.2)")
    session.output.should eq("Speakers")
    session.input.should eq("Microphone")
  end

  it "handles absent servers, malformed lists and missing device descriptions" do
    SystemView::AudioSessionDiscovery.scan(->(_arguments : Array(String)) { "" }).server.should be_empty
    SystemView::AudioSessionDiscovery.description("invalid", "sink.1").should eq("sink.1")
    SystemView::AudioSessionDiscovery.description(%([{"name":"sink.1"}]), "sink.1").should eq("sink.1")
  end
end
