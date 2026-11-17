require "../../src/inventory"
require "../../src/display_config"

def display_reply : GLib::Variant
  GLib::Variant.parse(<<-STATE)
    (uint32 1,
      [(('DP-1', 'DEL', 'ExamplePanel', ''), [('dp', 1920, 1080, 75.0, 1.0, [1.0], {'is-current': <true>})], {'is-builtin': <false>}),
       (('eDP-1', 'DEL', 'Built-in', 'panel'), [('edp', 2560, 1600, 120.0, 1.0, [1.0], {'is-current': <true>})], {'is-builtin': <true>}),
       (('HDMI-1', 'ACR', 'External', 'external'), @a(siiddada{sv}) [], {'is-builtin': <false>})],
      [(1920, 0, 1.0, uint32 0, true, [('DP-1', 'DEL', 'ExamplePanel', '')], @a{sv} {}),
       (0, 0, 1.0, 0, false, [('eDP-1', 'DEL', 'Built-in', 'panel')], {})],
      @a{sv} {})
    STATE
end
