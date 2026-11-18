require "libadwaita"
require "./i18n"
require "./metadata"
require "./app"

if ARGV == [SystemView::PrinterDiscovery::HELPER_ARGUMENT]
  names = SystemView::PrinterDiscovery.cups_names
  exit 1 unless names
  puts names.to_json
else
  exit(SystemView::GtkRuntime.run(SystemView::App.new))
end
