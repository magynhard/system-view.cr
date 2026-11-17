require "json"

module SystemView
  record RamIdentity, manufacturer : String, series : String do
    include JSON::Serializable
  end

  module RamIdentifiers
    extend self

    MAPPINGS = Hash(String, RamIdentity).from_json({{read_file("#{__DIR__}/../data/ram-identifiers.json")}})
    PREFIXES = MAPPINGS.keys.sort_by { |prefix| {-prefix.size, prefix} }

    def identify(part_number : String, reported_manufacturer : String = "") : RamIdentity
      normalized = part_number.strip.upcase
      prefix = PREFIXES.find { |candidate| normalized.starts_with?(candidate) }
      mapped = prefix ? MAPPINGS[prefix] : RamIdentity.new("", "")
      manufacturer = reported_manufacturer.strip
      manufacturer = "" if {"unknown", "not specified", "not provided", "<bad index>"}.includes?(manufacturer.downcase)
      RamIdentity.new(manufacturer.empty? ? mapped.manufacturer : manufacturer, mapped.series)
    end
  end
end
