require "./network"

module SystemView::SettingsAvailability
  extend self

  SERVICE = "org.gnome.Settings"
  alias Query = Proc(String, GLib::Variant?, GLib::Variant?)

  def available?(query : Query = ->call(String, GLib::Variant?)) : Bool
    owner = query.call("NameHasOwner", GLib::Variant.parse("('#{SERVICE}',)"))
    return true if owner && NetworkValue.new(owner).children.first?.try(&.boolean) == true
    names = query.call("ListActivatableNames", nil)
    names.try { |reply| NetworkValue.new(reply).children.first?.try(&.children.any? { |name| name.string == SERVICE }) } || false
  rescue GLib::Error
    false
  end

  private def call(method : String, parameters : GLib::Variant?) : GLib::Variant?
    bus = Gio.bus_get_sync(:session, nil)
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", method, parameters, nil, :none, 1_000, nil)
  rescue GLib::Error
    nil
  end
end
