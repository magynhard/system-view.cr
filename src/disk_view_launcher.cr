require "gi-crystal/gio"

lib LibGio
  fun g_desktop_app_info_new(desktop_id : UInt8*) : Void*
end

module SystemView::DiskViewLauncher
  extend self

  DESKTOP_ID = "de.magynhard.DiskView.desktop"

  def available? : Bool
    !app_info.nil?
  end

  def launch : Nil
    app_info.try(&.launch(nil, nil))
  rescue GLib::Error
    nil
  end

  private def app_info : Gio::AbstractAppInfo?
    pointer = LibGio.g_desktop_app_info_new(DESKTOP_ID)
    Gio::AbstractAppInfo.new(pointer, GICrystal::Transfer::Full) unless pointer.null?
  end
end
