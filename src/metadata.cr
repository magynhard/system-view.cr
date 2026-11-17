module SystemView
  APP_ID       = I18n::DOMAIN
  AUTHOR       = "Matthäus J. N. Beyrle"
  AUTHOR_EMAIL = "system-view.github.com@mail.magynhard.de"
  VERSION      = {{read_file("#{__DIR__}/../shard.yml").split("version: ")[1].split("\n")[0]}}

  RESOURCE_DATA = {{read_file("#{__DIR__}/../data/system-view.gresource")}}
  RESOURCE      = Gio::Resource.new_from_data(GLib::Bytes.new(RESOURCE_DATA.to_unsafe, RESOURCE_DATA.bytesize))
end
