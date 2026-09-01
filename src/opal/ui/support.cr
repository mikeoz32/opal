require "../live_view/html"
require "set"

module LF::UI
  extend self

  private EMPTY_ATTRIBUTES = {} of String => String

  private SAFE_GLOBAL_ATTRIBUTES = Set{
    "accesskey",
    "autocapitalize",
    "autofocus",
    "contenteditable",
    "dir",
    "draggable",
    "enterkeyhint",
    "hidden",
    "id",
    "inert",
    "inputmode",
    "lang",
    "nonce",
    "popover",
    "role",
    "spellcheck",
    "tabindex",
    "title",
    "translate",
  }
  private ATTRIBUTE_NAME = /\A[a-zA-Z_:][a-zA-Z0-9:._-]*\z/

  private def component_attributes(
    base_classes : String,
    class_name : String?,
    attributes : Hash(String, String),
    fixed = {} of String => String,
    booleans = [] of String,
  ) : LF::LiveView::HTML::Safe
    reserved = Set{"class"}
    fixed.each_key { |name| reserved << name }
    booleans.each { |name| reserved << name }

    attributes.each_key do |name|
      if reserved.includes?(name.downcase)
        raise ArgumentError.new("UI attribute '#{name}' must use its typed component argument")
      end
      validate_custom_attribute!(name)
    end

    classes = class_name.try { |extra| extra.blank? ? base_classes : "#{base_classes} #{extra}" } || base_classes
    markup = String.build do |html|
      html << %( class=") << LF::LiveView::HTML.escape(classes) << '"'
      fixed.each do |name, value|
        html << ' ' << name << %(=") << LF::LiveView::HTML.escape(value) << '"'
      end
      booleans.each { |name| html << ' ' << name }
      attributes.each do |name, value|
        html << ' ' << name << %(=") << LF::LiveView::HTML.escape(value) << '"'
      end
    end
    LF::LiveView::HTML.raw(markup)
  end

  private def validate_custom_attribute!(name : String) : Nil
    normalized = name.downcase
    valid = ATTRIBUTE_NAME.matches?(name) && (
      SAFE_GLOBAL_ATTRIBUTES.includes?(normalized) ||
      normalized.starts_with?("aria-") ||
      normalized.starts_with?("data-")
    )
    unless valid
      raise ArgumentError.new(
        "Unsafe UI attribute '#{name}'; use a typed argument, data-*, aria-*, or a safe global attribute"
      )
    end
  end

  private def validate_id!(id : String) : Nil
    raise ArgumentError.new("UI element id must not be blank") if id.blank?
    if id.each_char.any?(&.whitespace?)
      raise ArgumentError.new("UI element id must not contain whitespace")
    end
  end

  private def validate_href!(href : String) : Nil
    value = href.strip
    raise ArgumentError.new("UI link href must not be blank") if value.blank?
    if value.each_char.any? { |char| char.control? }
      raise ArgumentError.new("UI link href must not contain control characters")
    end

    colon = value.index(':')
    boundary = [value.index('/'), value.index('?'), value.index('#')].compact.min?
    if colon && (boundary.nil? || colon < boundary)
      scheme = value[0...colon].downcase
      unless {"http", "https", "mailto", "tel"}.includes?(scheme)
        raise ArgumentError.new("Unsafe UI link scheme '#{scheme}'")
      end
    end
  end

  private def tone_name(tone : Tone) : String
    tone.to_s.downcase
  end

  private def size_name(size : Size) : String
    size.to_s.downcase
  end

  private def optional_text(value : String?, id : String, classes : String) : LF::LiveView::Rendered
    return LF::LiveView::Rendered.opaque("") unless value

    LF::LiveView::HTML.rendered(%(<p id="#{id}" class="#{classes}">#{value}</p>))
  end
end
