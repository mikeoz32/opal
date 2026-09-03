module LF::UI
  TOOLTIP_TRIGGER = "inline-flex min-h-8 min-w-8 cursor-help items-center justify-center rounded-full border border-slate-300 bg-white px-2 text-sm font-semibold text-slate-700 outline-none transition-colors hover:bg-slate-100 focus-visible:ring-2 focus-visible:ring-blue-600 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-200 dark:hover:bg-slate-800"
  TOOLTIP_CONTENT = "pointer-events-none absolute z-[70] w-max max-w-xs rounded-lg bg-slate-950 px-3 py-2 text-xs font-medium leading-5 text-white shadow-lg dark:bg-slate-100 dark:text-slate-950"

  # Renders a button trigger and descriptive tooltip. Visibility is ephemeral
  # browser state and never consumes a LiveView component identity.
  def tooltip(
    trigger,
    content,
    *,
    id : String,
    trigger_label : String? = nil,
    position : TooltipPosition = TooltipPosition::Top,
    delay_ms : Int32 = 300,
    class_name : String? = nil,
    trigger_class_name : String? = nil,
    content_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
    trigger_attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    if trigger_label && trigger_label.blank?
      raise ArgumentError.new("UI tooltip trigger label must not be blank")
    end
    if delay_ms < 0
      raise ArgumentError.new("UI tooltip delay must not be negative")
    end

    content_id = "#{id}-content"
    root_attrs = component_attributes(
      "relative inline-flex",
      class_name,
      attributes,
      {
        "id"                      => id,
        "data-opal-ui"            => "tooltip",
        "data-opal-tooltip-open"  => "false",
        "data-opal-tooltip-delay" => delay_ms.to_s,
        "phx-hook"                => "OpalTooltip",
      }
    )
    trigger_fixed = {
      "id"                        => "#{id}-trigger",
      "type"                      => "button",
      "aria-describedby"          => content_id,
      "data-opal-ui"              => "tooltip-trigger",
      "data-opal-tooltip-trigger" => "",
    }
    trigger_label.try { |value| trigger_fixed["aria-label"] = value }
    trigger_attrs = component_attributes(
      TOOLTIP_TRIGGER,
      trigger_class_name,
      trigger_attributes,
      trigger_fixed
    )
    tooltip_attrs = component_attributes(
      "#{TOOLTIP_CONTENT} #{tooltip_position_classes(position)}",
      content_class_name,
      EMPTY_ATTRIBUTES,
      {
        "id"                        => content_id,
        "role"                      => "tooltip",
        "data-opal-ui"              => "tooltip-content",
        "data-opal-tooltip-content" => "",
      },
      ["hidden"]
    )

    LF::LiveView::HTML.rendered(<<-HTML)
      <span#{root_attrs}>
        <button#{trigger_attrs}>#{trigger}</button>
        <span#{tooltip_attrs}>#{content}</span>
      </span>
    HTML
  end

  private def tooltip_position_classes(position : TooltipPosition) : String
    case position
    when .top?    then "bottom-full left-1/2 mb-2 -translate-x-1/2"
    when .right?  then "left-full top-1/2 ml-2 -translate-y-1/2"
    when .bottom? then "left-1/2 top-full mt-2 -translate-x-1/2"
    when .left?   then "right-full top-1/2 mr-2 -translate-y-1/2"
    else               raise "Unsupported UI tooltip position"
    end
  end
end
