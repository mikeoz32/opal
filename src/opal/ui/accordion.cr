module LF::UI
  ACCORDION_ITEM    = "border-b border-slate-200 last:border-b-0 dark:border-slate-800"
  ACCORDION_TRIGGER = "flex w-full cursor-pointer items-center justify-between gap-4 py-4 text-left font-semibold text-slate-900 outline-none transition-colors hover:text-blue-700 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-600 disabled:pointer-events-none disabled:opacity-50 dark:text-slate-100 dark:hover:text-blue-300"
  ACCORDION_PANEL   = "pb-4 text-sm leading-6 text-slate-600 dark:text-slate-300"

  # Accordion expansion is application state. The hook only adds optional
  # ArrowUp/ArrowDown/Home/End focus movement between enabled triggers.
  def accordion(
    content,
    *,
    id : String,
    label : String? = nil,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    if label && label.blank?
      raise ArgumentError.new("UI accordion label must not be blank")
    end
    fixed = {
      "id"           => id,
      "role"         => "group",
      "data-opal-ui" => "accordion",
      "phx-hook"     => "OpalAccordion",
    }
    label.try { |value| fixed["aria-label"] = value }
    attrs = component_attributes(
      "rounded-xl border border-slate-200 px-4 dark:border-slate-800",
      class_name,
      attributes,
      fixed
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def accordion_item(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      ACCORDION_ITEM,
      class_name,
      attributes,
      {"data-opal-ui" => "accordion-item"}
    )
    LF::LiveView::HTML.rendered(%(<section#{attrs}>#{content}</section>))
  end

  def accordion_trigger(
    content,
    *,
    id : String,
    panel_id : String,
    expanded : Bool,
    toggle_event : String,
    value : String? = nil,
    heading_level : Int32 = 3,
    disabled : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(panel_id)
    validate_event!(toggle_event, "UI accordion toggle event")
    unless 1 <= heading_level <= 6
      raise ArgumentError.new("UI accordion heading level must be between 1 and 6")
    end
    fixed = {
      "id"                          => id,
      "type"                        => "button",
      "aria-expanded"               => expanded.to_s,
      "aria-controls"               => panel_id,
      "data-opal-ui"                => "accordion-trigger",
      "data-opal-accordion-trigger" => "",
      "phx-click"                   => toggle_event,
      "phx-value-item"              => value || id,
    }
    attrs = component_attributes(
      ACCORDION_TRIGGER,
      class_name,
      attributes,
      fixed,
      disabled ? ["disabled"] : [] of String
    )
    indicator_classes = expanded ? "shrink-0 rotate-180 transition-transform" : "shrink-0 transition-transform"
    button = LF::LiveView::HTML.rendered(
      %(<button#{attrs}><span>#{content}</span><span class="#{indicator_classes}" aria-hidden="true">⌄</span></button>)
    )
    accordion_heading(button, heading_level)
  end

  def accordion_panel(
    content,
    *,
    id : String,
    labelled_by : String,
    expanded : Bool,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(labelled_by)
    attrs = component_attributes(
      ACCORDION_PANEL,
      class_name,
      attributes,
      {
        "id"              => id,
        "role"            => "region",
        "aria-labelledby" => labelled_by,
        "data-opal-ui"    => "accordion-panel",
      },
      expanded ? [] of String : ["hidden"]
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  private def accordion_heading(content, level : Int32) : LF::LiveView::Rendered
    case level
    when 1 then LF::LiveView::HTML.rendered(%(<h1>#{content}</h1>))
    when 2 then LF::LiveView::HTML.rendered(%(<h2>#{content}</h2>))
    when 3 then LF::LiveView::HTML.rendered(%(<h3>#{content}</h3>))
    when 4 then LF::LiveView::HTML.rendered(%(<h4>#{content}</h4>))
    when 5 then LF::LiveView::HTML.rendered(%(<h5>#{content}</h5>))
    else        LF::LiveView::HTML.rendered(%(<h6>#{content}</h6>))
    end
  end
end
