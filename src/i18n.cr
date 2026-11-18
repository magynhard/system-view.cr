require "gettext"

module SystemView::I18n
  extend self

  DOMAIN = "de.magynhard.SystemView"

    def setup(locale_dir : String = default_locale_dir) : Nil
      LibC.setlocale(Gettext::LC::ALL, "C") if LibC.setlocale(Gettext::LC::ALL, "").null?
      if ENV["SYSTEM_VIEW_LANGUAGE"]? == "en"
        ENV["LANGUAGE"] = "en"
        LibC.setlocale(Gettext::LC::MESSAGES, "C.UTF-8") || LibC.setlocale(Gettext::LC::MESSAGES, "C")
      end
      Gettext.bindtextdomain(DOMAIN, locale_dir)
    Gettext.bind_textdomain_codeset(DOMAIN, "UTF-8")
  end

  def default_locale_dir : String
    executable_dir = File.dirname(Process.executable_path || PROGRAM_NAME)
    installed = File.expand_path("../share/locale", executable_dir)
    return installed if Dir.exists?(installed)
    development = File.expand_path("../po", executable_dir)
    return development if Dir.exists?(development)
    File.expand_path("../po", __DIR__)
  end

  def bind_toolkit_domains : Nil
    directory = default_locale_dir
    {"gtk40", "libadwaita", "glib20"}.each do |domain|
      next if Dir.glob(File.join(directory, "*", "LC_MESSAGES", "#{domain}.mo")).empty?
      Gettext.bindtextdomain(domain, directory)
      Gettext.bind_textdomain_codeset(domain, "UTF-8")
    end
  end

  def translate(message : String, **values) : String
    translated = Gettext.dgettext(DOMAIN, message)
    values.empty? ? translated : translated % values
  end
end
