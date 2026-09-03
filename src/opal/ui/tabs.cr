module LF::UI
  def tabs(
    content,
    *,
    id : String,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    attrs = component_attributes(
      "w-full",
      class_name,
      attributes,
      {
        "id"           => id,
        "data-opal-ui" => "tabs",
        "phx-hook"     => "OpalTabs",
      }
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def tab_list(
    content,
    *,
    label : String,
    orientation : TabsOrientation = TabsOrientation::Horizontal,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    if label.blank?
      raise ArgumentError.new("UI tab list label must not be blank")
    end
    vertical = orientation == TabsOrientation::Vertical
    classes = if vertical
                "flex flex-col gap-1 border-r border-slate-200 pr-3 dark:border-slate-800"
              else
                "flex gap-1 overflow-x-auto border-b border-slate-200 dark:border-slate-800"
              end
    attrs = component_attributes(
      classes,
      class_name,
      attributes,
      {
        "role"               => "tablist",
        "aria-label"         => label,
        "aria-orientation"   => vertical ? "vertical" : "horizontal",
        "data-opal-ui"       => "tab-list",
        "data-opal-tab-list" => "",
      }
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def tab(
    content,
    *,
    id : String,
    panel_id : String,
    selected : Bool,
    select_event : String,
    value : String? = nil,
    disabled : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(panel_id)
    validate_event!(select_event, "UI tab select event")
    state_classes = if selected
                      "border-blue-600 text-blue-700 dark:border-blue-400 dark:text-blue-300"
                    else
                      "border-transparent text-slate-600 hover:border-slate-300 hover:text-slate-900 dark:text-slate-400 dark:hover:border-slate-700 dark:hover:text-slate-100"
                    end
    fixed = {
      "id"            => id,
      "type"          => "button",
      "role"          => "tab",
      "aria-selected" => selected.to_s,
      "aria-controls" => panel_id,
      "tabindex"      => selected ? "0" : "-1",
      "data-opal-ui"  => "tab",
      "data-opal-tab" => "",
      "phx-click"     => select_event,
      "phx-value-tab" => value || id,
    }
    booleans = disabled ? ["disabled"] : [] of String
    attrs = component_attributes(
      "-mb-px cursor-pointer whitespace-nowrap border-b-2 px-4 py-3 text-sm font-semibold outline-none transition-colors focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-600 disabled:pointer-events-none disabled:opacity-50 #{state_classes}",
      class_name,
      attributes,
      fixed,
      booleans
    )
    LF::LiveView::HTML.rendered(%(<button#{attrs}>#{content}</button>))
  end

  def tab_panel(
    content,
    *,
    id : String,
    labelled_by : String,
    selected : Bool,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(labelled_by)
    attrs = component_attributes(
      "rounded-b-xl py-5 outline-none focus-visible:ring-2 focus-visible:ring-blue-600",
      class_name,
      attributes,
      {
        "id"              => id,
        "role"            => "tabpanel",
        "aria-labelledby" => labelled_by,
        "tabindex"        => "0",
        "data-opal-ui"    => "tab-panel",
      },
      selected ? [] of String : ["hidden"]
    )
    LF::LiveView::HTML.rendered(%(<section#{attrs}>#{content}</section>))
  end
end
