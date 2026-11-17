require "libadwaita"
require "./i18n"
require "./metadata"
require "./app"

exit(SystemView::GtkRuntime.run(SystemView::App.new))
