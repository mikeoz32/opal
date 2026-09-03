module LF::UI
  BUTTON_BASE = "inline-flex cursor-pointer select-none items-center justify-center gap-2 whitespace-nowrap rounded-lg font-[inherit] font-semibold no-underline transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 dark:focus-visible:ring-offset-slate-950"

  def button(
    content,
    *,
    variant : ButtonVariant = ButtonVariant::Solid,
    tone : Tone = Tone::Primary,
    size : Size = Size::Medium,
    type : String = "button",
    disabled : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    unless {"button", "reset", "submit"}.includes?(type)
      raise ArgumentError.new("UI button type must be button, reset, or submit")
    end

    fixed = {
      "type"            => type,
      "data-opal-ui"    => "button",
      "data-ui-tone"    => tone_name(tone),
      "data-ui-size"    => size_name(size),
      "data-ui-variant" => variant.to_s.downcase,
    }
    booleans = disabled ? ["disabled"] : [] of String
    attrs = component_attributes(
      "#{BUTTON_BASE} #{button_size_classes(size)} #{button_variant_classes(variant, tone)}",
      class_name,
      attributes,
      fixed,
      booleans
    )
    LF::LiveView::HTML.rendered(%(<button#{attrs}>#{content}</button>))
  end

  def link_button(
    content,
    href : String,
    *,
    variant : ButtonVariant = ButtonVariant::Solid,
    tone : Tone = Tone::Primary,
    size : Size = Size::Medium,
    disabled : Bool = false,
    target : String? = nil,
    rel : String? = nil,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_href!(href)
    fixed = {
      "data-opal-ui"    => "link-button",
      "data-ui-tone"    => tone_name(tone),
      "data-ui-size"    => size_name(size),
      "data-ui-variant" => variant.to_s.downcase,
    }
    unless disabled
      fixed["href"] = href
    else
      fixed["aria-disabled"] = "true"
      fixed["tabindex"] = "-1"
    end
    if target
      fixed["target"] = target
      fixed["rel"] = rel || (target == "_blank" ? "noopener noreferrer" : "")
    elsif rel
      fixed["rel"] = rel
    end

    attrs = component_attributes(
      "#{BUTTON_BASE} #{button_size_classes(size)} #{button_variant_classes(variant, tone)}",
      class_name,
      attributes,
      fixed
    )
    LF::LiveView::HTML.rendered(%(<a#{attrs}>#{content}</a>))
  end

  private def button_size_classes(size : Size) : String
    case size
    when .small?  then "min-h-8 px-3 py-1.5 text-sm"
    when .medium? then "min-h-10 px-4 py-2 text-sm"
    when .large?  then "min-h-12 px-5 py-3 text-base"
    else               raise "Unsupported UI button size"
    end
  end

  private def button_variant_classes(variant : ButtonVariant, tone : Tone) : String
    case {variant, tone}
    when {ButtonVariant::Solid, Tone::Neutral}
      "border border-transparent bg-slate-700 text-white hover:bg-slate-800 focus-visible:ring-slate-600 dark:bg-slate-200 dark:text-slate-950 dark:hover:bg-white"
    when {ButtonVariant::Solid, Tone::Primary}
      "border border-transparent bg-blue-600 text-white hover:bg-blue-700 focus-visible:ring-blue-600 dark:bg-blue-500 dark:hover:bg-blue-400"
    when {ButtonVariant::Solid, Tone::Success}
      "border border-transparent bg-emerald-600 text-white hover:bg-emerald-700 focus-visible:ring-emerald-600 dark:bg-emerald-500 dark:hover:bg-emerald-400"
    when {ButtonVariant::Solid, Tone::Warning}
      "border border-transparent bg-amber-500 text-slate-950 hover:bg-amber-600 focus-visible:ring-amber-500 dark:bg-amber-400 dark:hover:bg-amber-300"
    when {ButtonVariant::Solid, Tone::Danger}
      "border border-transparent bg-red-600 text-white hover:bg-red-700 focus-visible:ring-red-600 dark:bg-red-500 dark:hover:bg-red-400"
    when {ButtonVariant::Outline, Tone::Neutral}
      "border border-slate-300 bg-white text-slate-800 hover:bg-slate-100 focus-visible:ring-slate-500 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:hover:bg-slate-800"
    when {ButtonVariant::Outline, Tone::Primary}
      "border border-blue-300 bg-white text-blue-700 hover:bg-blue-50 focus-visible:ring-blue-600 dark:border-blue-700 dark:bg-slate-950 dark:text-blue-300 dark:hover:bg-blue-950"
    when {ButtonVariant::Outline, Tone::Success}
      "border border-emerald-300 bg-white text-emerald-700 hover:bg-emerald-50 focus-visible:ring-emerald-600 dark:border-emerald-700 dark:bg-slate-950 dark:text-emerald-300 dark:hover:bg-emerald-950"
    when {ButtonVariant::Outline, Tone::Warning}
      "border border-amber-300 bg-white text-amber-800 hover:bg-amber-50 focus-visible:ring-amber-500 dark:border-amber-700 dark:bg-slate-950 dark:text-amber-300 dark:hover:bg-amber-950"
    when {ButtonVariant::Outline, Tone::Danger}
      "border border-red-300 bg-white text-red-700 hover:bg-red-50 focus-visible:ring-red-600 dark:border-red-700 dark:bg-slate-950 dark:text-red-300 dark:hover:bg-red-950"
    when {ButtonVariant::Ghost, Tone::Neutral}
      "border border-transparent text-slate-700 hover:bg-slate-100 focus-visible:ring-slate-500 dark:text-slate-200 dark:hover:bg-slate-800"
    when {ButtonVariant::Ghost, Tone::Primary}
      "border border-transparent text-blue-700 hover:bg-blue-50 focus-visible:ring-blue-600 dark:text-blue-300 dark:hover:bg-blue-950"
    when {ButtonVariant::Ghost, Tone::Success}
      "border border-transparent text-emerald-700 hover:bg-emerald-50 focus-visible:ring-emerald-600 dark:text-emerald-300 dark:hover:bg-emerald-950"
    when {ButtonVariant::Ghost, Tone::Warning}
      "border border-transparent text-amber-800 hover:bg-amber-50 focus-visible:ring-amber-500 dark:text-amber-300 dark:hover:bg-amber-950"
    when {ButtonVariant::Ghost, Tone::Danger}
      "border border-transparent text-red-700 hover:bg-red-50 focus-visible:ring-red-600 dark:text-red-300 dark:hover:bg-red-950"
    else
      raise "Unsupported UI button variant"
    end
  end
end
