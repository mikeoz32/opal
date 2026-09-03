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

  private LEGACY_LIVE_VIEW_BINDINGS = Set{
    "data-opal-auto-recover",
    "data-opal-blur",
    "data-opal-click",
    "data-opal-click-away",
    "data-opal-change",
    "data-opal-connected",
    "data-opal-debounce",
    "data-opal-disable-with",
    "data-opal-disconnected",
    "data-opal-drop-target",
    "data-opal-focus",
    "data-opal-hook",
    "data-opal-key",
    "data-opal-keydown",
    "data-opal-keyup",
    "data-opal-mounted",
    "data-opal-no-unused-field",
    "data-opal-patch-focused",
    "data-opal-progress",
    "data-opal-remove",
    "data-opal-submit",
    "data-opal-target",
    "data-opal-throttle",
    "data-opal-track-static",
    "data-opal-trigger-action",
    "data-opal-update",
    "data-opal-viewport-bottom",
    "data-opal-viewport-overrun-target",
    "data-opal-viewport-top",
    "data-opal-window-blur",
    "data-opal-window-focus",
    "data-opal-window-keydown",
    "data-opal-window-keyup",
  }

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
    if LEGACY_LIVE_VIEW_BINDINGS.includes?(normalized) || normalized.starts_with?("data-opal-value-")
      replacement = normalized.sub("data-opal-", "phx-")
      raise ArgumentError.new("Legacy UI LiveView binding '#{name}'; use '#{replacement}'")
    end
    valid = ATTRIBUTE_NAME.matches?(name) && (
      SAFE_GLOBAL_ATTRIBUTES.includes?(normalized) ||
      normalized.starts_with?("aria-") ||
      normalized.starts_with?("data-") ||
      normalized.starts_with?("phx-")
    )
    unless valid
      raise ArgumentError.new(
        "Unsafe UI attribute '#{name}'; use a typed argument, phx-*, data-*, aria-*, or a safe global attribute"
      )
    end
  end

  private def validate_id!(id : String) : Nil
    raise ArgumentError.new("UI element id must not be blank") if id.blank?
    if id.each_char.any?(&.whitespace?)
      raise ArgumentError.new("UI element id must not contain whitespace")
    end
  end

  private def validate_event!(event : String, label : String) : Nil
    if event.blank? || event.each_char.any?(&.control?)
      raise ArgumentError.new("#{label} must not be blank or contain control characters")
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
