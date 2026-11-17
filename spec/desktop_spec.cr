require "spec"
require "./support/fixture_files"
require "../src/desktop"

describe SystemView::DesktopEnvironment do
  it "recognizes desktop names without guessing from installed applications" do
    SystemView::DesktopEnvironment.name("ubuntu:GNOME").should eq("GNOME")
    SystemView::DesktopEnvironment.name("gnome").should eq("GNOME")
    SystemView::DesktopEnvironment.name("KDE").should eq("KDE Plasma")
    SystemView::DesktopEnvironment.name("XFCE").should eq("Xfce")
    SystemView::DesktopEnvironment.name("X-Cinnamon").should eq("Cinnamon")
    SystemView::DesktopEnvironment.name("").should eq("")
  end

  it "falls back to the host GNOME version metadata when no session bus exists" do
    previous = ENV.delete("DBUS_SESSION_BUS_ADDRESS")
    begin
      files = FixtureFiles.new
      files.files["/usr/share/gnome/gnome-version.xml"] = "<gnome-version><platform>50</platform><minor>5</minor><micro>0</micro></gnome-version>"
      SystemView::DesktopEnvironment.detect(files, "GNOME").should eq("GNOME 50.5.0")
      SystemView::DesktopEnvironment.detect(files, "KDE").should eq("KDE Plasma")
    ensure
      ENV["DBUS_SESSION_BUS_ADDRESS"] = previous if previous
    end
  end
end
