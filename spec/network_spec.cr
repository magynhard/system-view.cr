require "spec"
require "./support/network_fixture"

describe SystemView::NetworkDiscovery do
  it "combines per-interface LAN configuration with physical link parameters" do
    data = SystemView::NetworkDiscovery.scan(network_files, FixtureNetworkBus.new)
    lan = data.devices.find { |device| device.interface == "enp1s0" }.not_nil!
    lan.name.should eq("Realtek Example 2.5GbE")
    lan.kind.should eq("ethernet")
    lan.speed_mbps.should eq(2500)
    lan.duplex.should eq("full")
    lan.mac.should eq("02:11:22:33:44:55")
    lan.permanent_mac.should eq("00:11:22:33:44:55")
    lan.ipv4.addresses.should eq(["192.0.2.10/24"])
    lan.ipv4.dhcp.should be_true
    lan.ipv4.dns.should eq(["192.0.2.53", "192.0.2.54"])
    lan.ipv4.gateway.should eq("192.0.2.1")
    lan.ipv4.domains.should eq(["example.test"])
    lan.ipv6.addresses.should eq(["2001:db8::10/64", "fe80::10/64"])
    lan.ipv6.dhcp.should be_nil # An automatic IPv6 profile may use SLAAC alone.
    lan.ipv6.gateway.should eq("fe80::1")
    lan.ipv6.dns.should eq(["2001:db8:0:0:0:0:0:53"])
    lan.ipv6.dhcp.should be_nil # IPv6 auto may be SLAAC; do not assume DHCP.
  end

  it "reads only the active Wi-Fi access point without scanning or mixing DNS" do
    bus = FixtureNetworkBus.new
    data = SystemView::NetworkDiscovery.scan(network_files, bus)
    wifi = data.devices.find { |device| device.kind == "wifi" }.not_nil!
    wifi.ssid.should eq("Test ä")
    wifi.speed_mbps.should eq(866.7)
    wifi.signal.should eq(82)
    wifi.frequency_mhz.should eq(5180)
    wifi.security.should eq("WPA2 / WPA3")
    wifi.bssid.should eq("00:ab:cd:ef:12:34")
    wifi.ipv4.dhcp.should be_false
    wifi.ipv4.dns.should eq(["198.51.100.53"])
    wifi.ipv6.available.should be_true
    wifi.ipv6.dhcp.should be_false
    bus.calls.map(&.[2]).uniq.sort.should eq(["GetAll", "GetDevices", "GetManagedObjects", "GetSettings"])
  end

  it "lists Bluetooth adapters and paired or connected devices without discovery" do
    data = SystemView::NetworkDiscovery.scan(network_files, FixtureNetworkBus.new)
    adapter = data.bluetooth.first
    adapter.name.should eq("Example Bluetooth")
    adapter.version.should eq("5.3")
    adapter.powered.should be_true
    adapter.discoverable.should be_false
    adapter.devices.map(&.name).should eq(["Headphones", "Old mouse"])
    adapter.devices.first.rssi.should eq(-48)
  end

  it "retains physical links without D-Bus and does not invent address or DNS data" do
    files = network_files
    files.directories["/sys/class/bluetooth"] = ["hci0", "hci0:1"]
    data = SystemView::NetworkDiscovery.scan(files)
    data.devices.map(&.interface).should eq(["enp1s0", "enp2s0", "wlan0"])
    lan = data.devices.first
    lan.state.should eq("connected")
    lan.speed_mbps.should eq(2500)
    lan.ipv4.available.should be_false
    lan.ipv4.dhcp.should be_nil
    lan.ipv4.dns.should be_empty
    unplugged = data.devices[1]
    unplugged.state.should eq("disconnected")
    unplugged.speed_mbps.should eq(0)
    data.bluetooth.map(&.id).should eq(["hci0"])
    data.bluetooth.first.powered.should be_nil
  end

  it "does not mistake OWE for WPA3 authentication or corrupt unusual SSIDs" do
    bus = FixtureNetworkBus.new
    bus.properties[{"/nm/AP/1", "org.freedesktop.NetworkManager.AccessPoint"}] = "({'Ssid': <[byte 0x3c, 0x26, 0x00, 0xff]>, 'RsnFlags': <uint32 2048>},)"
    wifi = SystemView::NetworkDiscovery.scan(network_files, bus).devices.find { |device| device.kind == "wifi" }.not_nil!
    wifi.security.should eq("OWE")
    wifi.ssid.should eq("<&��")
  end

  it "handles empty inventories and unavailable services independently" do
    bus = FixtureNetworkBus.new
    bus.properties.clear
    bus.replies.clear
    data = SystemView::NetworkDiscovery.scan(FixtureFiles.new, bus)
    data.devices.should be_empty
    data.bluetooth.should be_empty
  end

  it "keeps Bluetooth available when NetworkManager is absent and vice versa" do
    bus = FixtureNetworkBus.new
    bus.replies.delete({"/org/freedesktop/NetworkManager", "GetDevices"})
    data = SystemView::NetworkDiscovery.scan(network_files, bus)
    data.devices.first.ipv4.available.should be_false
    data.bluetooth.first.version.should eq("5.3")

    bus = FixtureNetworkBus.new
    bus.replies.delete({"/", "GetManagedObjects"})
    data = SystemView::NetworkDiscovery.scan(network_files, bus)
    data.devices.first.ipv4.gateway.should eq("192.0.2.1")
    data.bluetooth.should be_empty
  end
end
