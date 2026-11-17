require "spec"
require "../src/subprocess_output"

describe SystemView::SubprocessOutput do
  it "captures output beyond pipe capacity while waiting for the child" do
    process = SystemView::SubprocessOutput.launch(["/bin/sh", "-c", "i=0; while [ $i -lt 1024 ]; do printf '%0128d' 0; i=$((i+1)); done"])
    output = SystemView::SubprocessOutput.read(process)
    output.bytesize.should eq(131_072)
    output.each_byte.all?(&.==('0'.ord)).should be_true
    process.successful.should be_true
  end

  it "preserves failure status and scrubs non-UTF-8 bytes without dropping output" do
    process = SystemView::SubprocessOutput.launch(["/bin/sh", "-c", "printf 'output\\377'; exit 7"])
    SystemView::SubprocessOutput.read(process).should eq("output�")
    process.successful.should be_false
    process.exit_status.should eq(7)
  end

  it "sets child environment variables without changing the application's environment" do
    before = ENV["SYSTEM_VIEW_TEST_CHILD"]?
    process = SystemView::SubprocessOutput.launch(["/bin/sh", "-c", "printf '%s' \"$SYSTEM_VIEW_TEST_CHILD\""], {"SYSTEM_VIEW_TEST_CHILD" => "child-only"})
    SystemView::SubprocessOutput.read(process).should eq("child-only")
    ENV["SYSTEM_VIEW_TEST_CHILD"]?.should eq(before)
  end

  it "allows pending reads to be cancelled and the child to be terminated" do
    process = SystemView::SubprocessOutput.launch(["/bin/sleep", "5"])
    cancellable = Gio::Cancellable.new
    cancellable.cancel
    expect_raises(GLib::Error) { SystemView::SubprocessOutput.read(process, cancellable) }
    process.force_exit
    process.wait(nil).should be_true
    process.if_signaled.should be_true
  end
end
