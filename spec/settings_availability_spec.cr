require "spec"
require "../src/settings_availability"

describe SystemView::SettingsAvailability do
  it "recognizes a running settings service" do
    query = ->(method : String, _params : GLib::Variant?) : GLib::Variant? do
      method == "NameHasOwner" ? GLib::Variant.parse("(true,)") : nil
    end
    SystemView::SettingsAvailability.available?(query).should be_true
  end

  it "recognizes an activatable settings service" do
    query = ->(method : String, _params : GLib::Variant?) : GLib::Variant? do
      method == "NameHasOwner" ? GLib::Variant.parse("(false,)") : GLib::Variant.parse("(['org.gnome.Settings'],)")
    end
    SystemView::SettingsAvailability.available?(query).should be_true
  end

  it "hides settings when the service is missing or the bus is unavailable" do
    missing = ->(method : String, _params : GLib::Variant?) : GLib::Variant? do
      method == "NameHasOwner" ? GLib::Variant.parse("(false,)") : GLib::Variant.parse("(@as [],)")
    end
    unavailable = ->(_method : String, _params : GLib::Variant?) : GLib::Variant? { nil }
    SystemView::SettingsAvailability.available?(missing).should be_false
    SystemView::SettingsAvailability.available?(unavailable).should be_false
  end
end
