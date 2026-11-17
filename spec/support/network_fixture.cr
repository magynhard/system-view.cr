require "./fixture_files"

class FixtureNetworkBus < SystemView::NetworkBus
  getter properties = {} of Tuple(String, String) => String
  getter replies = {} of Tuple(String, String) => String
  getter calls = [] of Tuple(String, String, String)

  def initialize
    @replies[{"/org/freedesktop/NetworkManager", "GetDevices"}] = "(@ao ['/nm/Devices/1', '/nm/Devices/2'],)"
    @properties[{"/nm/Devices/1", "org.freedesktop.NetworkManager.Device"}] = "({'Interface': <'enp1s0'>, 'DeviceType': <uint32 1>, 'State': <uint32 100>, 'Driver': <'r8169'>, 'HwAddress': <'02:11:22:33:44:55'>, 'Mtu': <uint32 1500>, 'ActiveConnection': <objectpath '/nm/Active/1'>, 'Ip4Config': <objectpath '/nm/IP4/1'>, 'Ip6Config': <objectpath '/nm/IP6/1'>, 'Dhcp4Config': <objectpath '/nm/DHCP4/1'>, 'Dhcp6Config': <objectpath '/'>},)"
    @properties[{"/nm/Devices/1", "org.freedesktop.NetworkManager.Device.Wired"}] = "({'Speed': <uint32 2500>, 'PermHwAddress': <'00:11:22:33:44:55'>},)"
    @properties[{"/nm/Active/1", "org.freedesktop.NetworkManager.Connection.Active"}] = "({'Id': <'Wired connection'>, 'Connection': <objectpath '/nm/Settings/1'>},)"
    @replies[{"/nm/Settings/1", "GetSettings"}] = "({'ipv4': {'method': <'auto'>}, 'ipv6': {'method': <'auto'>}},)"
    @properties[{"/nm/IP4/1", "org.freedesktop.NetworkManager.IP4Config"}] = "({'AddressData': <[{'address': <'192.0.2.10'>, 'prefix': <uint32 24>}]>, 'Gateway': <'192.0.2.1'>, 'NameserverData': <[{'address': <'192.0.2.53'>}, {'address': <'192.0.2.54'>}]>, 'Domains': <['example.test']>},)"
    @properties[{"/nm/IP6/1", "org.freedesktop.NetworkManager.IP6Config"}] = "({'AddressData': <[{'address': <'2001:db8::10'>, 'prefix': <uint32 64>}, {'address': <'fe80::10'>, 'prefix': <uint32 64>}]>, 'Gateway': <'fe80::1'>, 'Nameservers': <[[byte 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53]]>},)"
    @properties[{"/nm/Devices/2", "org.freedesktop.NetworkManager.Device"}] = "({'Interface': <'wlan0'>, 'DeviceType': <uint32 2>, 'State': <uint32 100>, 'Driver': <'iwlwifi'>, 'HwAddress': <'02:aa:bb:cc:dd:ee'>, 'ActiveConnection': <objectpath '/nm/Active/2'>, 'Ip4Config': <objectpath '/nm/IP4/2'>, 'Ip6Config': <objectpath '/'>, 'Dhcp4Config': <objectpath '/'>, 'Dhcp6Config': <objectpath '/'>},)"
    @properties[{"/nm/Devices/2", "org.freedesktop.NetworkManager.Device.Wireless"}] = "({'Bitrate': <uint32 866700>, 'PermHwAddress': <'00:aa:bb:cc:dd:ee'>, 'ActiveAccessPoint': <objectpath '/nm/AP/1'>},)"
    @properties[{"/nm/AP/1", "org.freedesktop.NetworkManager.AccessPoint"}] = "({'Ssid': <[byte 0x54, 0x65, 0x73, 0x74, 0x20, 0xc3, 0xa4]>, 'HwAddress': <'00:ab:cd:ef:12:34'>, 'Strength': <byte 82>, 'Frequency': <uint32 5180>, 'Flags': <uint32 1>, 'WpaFlags': <uint32 0>, 'RsnFlags': <uint32 1280>},)"
    @properties[{"/nm/Active/2", "org.freedesktop.NetworkManager.Connection.Active"}] = "({'Id': <'Test Wi-Fi'>, 'Connection': <objectpath '/nm/Settings/2'>},)"
    @replies[{"/nm/Settings/2", "GetSettings"}] = "({'ipv4': {'method': <'manual'>}, 'ipv6': {'method': <'disabled'>}},)"
    @properties[{"/nm/IP4/2", "org.freedesktop.NetworkManager.IP4Config"}] = "({'AddressData': <[{'address': <'198.51.100.2'>, 'prefix': <uint32 24>}]>, 'Gateway': <'198.51.100.1'>, 'NameserverData': <[{'address': <'198.51.100.53'>}]>},)"
    @replies[{"/", "GetManagedObjects"}] = "({objectpath '/org/bluez/hci0': {'org.bluez.Adapter1': {'Alias': <'Example Bluetooth'>, 'Address': <'00:12:34:56:78:90'>, 'Powered': <true>, 'Discoverable': <false>, 'Pairable': <true>, 'Version': <byte 12>}}, objectpath '/org/bluez/hci0/dev_AA': {'org.bluez.Device1': {'Adapter': <objectpath '/org/bluez/hci0'>, 'Alias': <'Headphones'>, 'Address': <'AA:BB:CC:DD:EE:FF'>, 'Connected': <true>, 'Paired': <true>, 'RSSI': <int16 -48>}}, objectpath '/org/bluez/hci0/dev_BB': {'org.bluez.Device1': {'Adapter': <objectpath '/org/bluez/hci0'>, 'Alias': <'Old mouse'>, 'Address': <'BB:BB:CC:DD:EE:FF'>, 'Connected': <false>, 'Paired': <true>}}, objectpath '/org/bluez/hci0/dev_CC': {'org.bluez.Device1': {'Adapter': <objectpath '/org/bluez/hci0'>, 'Alias': <'Unpaired bystander'>, 'Connected': <false>, 'Paired': <false>}}},)"
  end

  def call(service : String, path : String, interface : String, method : String, parameters : GLib::Variant? = nil) : GLib::Variant?
    @calls << {service, interface, method}
    text = if method == "GetAll" && parameters
             name = SystemView::NetworkValue.new(parameters).children.first.string
             @properties[{path, name}]?
           else
             @replies[{path, method}]?
           end
    text.try { |value| GLib::Variant.parse(value) }
  end
end

def network_files : FixtureFiles
  files = FixtureFiles.new
  files.directories["/sys/class/net"] = ["lo", "enp1s0", "wlan0", "docker0", "veth123", "enp2s0"]
  files.directories["/sys/class/net/enp1s0/device"] = [] of String
  files.directories["/sys/class/net/enp2s0/device"] = [] of String
  files.directories["/sys/class/net/wlan0/wireless"] = [] of String
  {"enp1s0", "enp2s0", "wlan0"}.each do |name|
    files.files["/sys/class/net/#{name}/address"] = "00:11:22:33:44:55"
    files.files["/sys/class/net/#{name}/mtu"] = "1500"
    files.files["/sys/class/net/#{name}/operstate"] = name == "enp2s0" ? "down" : "up"
    files.files["/sys/class/net/#{name}/carrier"] = name == "enp2s0" ? "0" : "1"
  end
  files.files["/sys/class/net/enp1s0/speed"] = "2500"
  files.files["/sys/class/net/enp1s0/duplex"] = "full"
  files.files["/sys/class/net/enp2s0/speed"] = "-1"
  files.files["/sys/class/net/enp1s0/ifindex"] = "2"
  files.files["/run/udev/data/n2"] = "E:ID_VENDOR_FROM_DATABASE=Realtek\nE:ID_MODEL_FROM_DATABASE=Example 2.5GbE\n"
  files
end
