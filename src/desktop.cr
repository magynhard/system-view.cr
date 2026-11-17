require "gi-crystal/gio"

module SystemView::DesktopEnvironment
  extend self

  def name(current : String) : String
    components = current.upcase.split(/[:;]/)
    return "GNOME" if components.any? { |part| part.includes?("GNOME") }
    return "KDE Plasma" if components.any? { |part| part == "KDE" || part.includes?("PLASMA") }
    return "Xfce" if components.includes?("XFCE")
    return "Cinnamon" if components.any?(&.includes?("CINNAMON"))
    return "MATE" if components.includes?("MATE")
    return "LXQt" if components.includes?("LXQT")
    current.split(/[:;]/).first? || ""
  end

  def detect(files : LinuxFiles, current : String = ENV["XDG_CURRENT_DESKTOP"]? || ENV["XDG_SESSION_DESKTOP"]? || ENV["DESKTOP_SESSION"]? || "") : String
    desktop = name(current)
    version = desktop == "GNOME" ? gnome_version : ""
    if desktop == "GNOME" && version.empty?
      text = files.read("/usr/share/gnome/gnome-version.xml")
      parts = {"platform", "minor", "micro"}.compact_map { |tag| text.match(/<#{tag}>(\d+)<\/#{tag}>/).try(&.[1]) }
      version = parts.join(".") if parts.size == 3
    end
    [desktop, version].reject(&.empty?).join(" ")
  end

  def gnome_version : String
    return "" unless ENV["DBUS_SESSION_BUS_ADDRESS"]?
    connection = Gio.bus_get_sync(:session, nil)
    reply = connection.call_sync("org.gnome.Shell", "/org/gnome/Shell", "org.freedesktop.DBus.Properties", "Get",
      GLib::Variant.parse("('org.gnome.Shell', 'ShellVersion')"), nil, :no_auto_start, 500, nil)
    reply.to_s(false).match(/'([0-9][A-Za-z0-9.\-]*)'/).try(&.[1]) || ""
  rescue GLib::Error
    ""
  end
end
