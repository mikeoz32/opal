module LF::UI
  DROPDOWN_TRIGGER = "inline-flex min-h-10 cursor-pointer select-none items-center justify-center gap-2 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 transition-colors hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-600 focus-visible:ring-offset-2 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:hover:bg-slate-800 dark:focus-visible:ring-offset-slate-950"
  DROPDOWN_MENU    = "absolute z-50 mt-2 min-w-48 overflow-hidden rounded-xl border border-slate-200 bg-white p-1 shadow-lg dark:border-slate-800 dark:bg-slate-900"
  DROPDOWN_ITEM    = "flex w-full cursor-pointer items-center rounded-lg px-3 py-2 text-left text-sm text-slate-700 no-underline outline-none transition-colors hover:bg-slate-100 focus:bg-slate-100 disabled:pointer-events-none disabled:opacity-50 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:bg-slate-800"

  # Dropdown visibility and roving focus are local presentation state. Menu
  # item events and resulting application state continue to be owned by the
  # LiveView.
  def dropdown(
    content,
    *,
    id : String,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    attrs = component_attributes(
      "relative inline-block text-left",
      class_name,
      attributes,
      {
        "id"                      => id,
        "data-opal-ui"            => "dropdown",
        "data-opal-hook"          => "OpalDropdown",
        "data-opal-dropdown-open" => "false",
      }
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def dropdown_trigger(
    content,
    *,
    id : String,
    controls : String,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(controls)
    attrs = component_attributes(
      DROPDOWN_TRIGGER,
      class_name,
      attributes,
      {
        "id"                         => id,
        "type"                       => "button",
        "aria-haspopup"              => "menu",
        "aria-expanded"              => "false",
        "aria-controls"              => controls,
        "data-opal-ui"               => "dropdown-trigger",
        "data-opal-dropdown-trigger" => "",
      }
    )
    LF::LiveView::HTML.rendered(%(<button#{attrs}>#{content}</button>))
  end

  def dropdown_menu(
    content,
    *,
    id : String,
    labelled_by : String,
    align : MenuAlign = MenuAlign::Start,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(labelled_by)
    alignment = align == MenuAlign::End ? "right-0 origin-top-right" : "left-0 origin-top-left"
    attrs = component_attributes(
      "#{DROPDOWN_MENU} #{alignment}",
      class_name,
      attributes,
      {
        "id"                      => id,
        "role"                    => "menu",
        "aria-labelledby"         => labelled_by,
        "data-opal-ui"            => "dropdown-menu",
        "data-opal-dropdown-menu" => "",
      },
      ["hidden"]
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def dropdown_item(
    content,
    *,
    event : String? = nil,
    value : String? = nil,
    disabled : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    event.try { |name| validate_event!(name, "UI dropdown item event") }
    if value && event.nil?
      raise ArgumentError.new("UI dropdown item value requires an event")
    end
    fixed = {
      "type"                    => "button",
      "role"                    => "menuitem",
      "tabindex"                => "-1",
      "data-opal-ui"            => "dropdown-item",
      "data-opal-dropdown-item" => "",
    }
    event.try { |name| fixed["data-opal-click"] = name }
    value.try { |item| fixed["data-opal-value-item"] = item }
    booleans = disabled ? ["disabled"] : [] of String
    attrs = component_attributes(DROPDOWN_ITEM, class_name, attributes, fixed, booleans)
    LF::LiveView::HTML.rendered(%(<button#{attrs}>#{content}</button>))
  end

  def dropdown_link(
    content,
    href : String,
    *,
    disabled : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_href!(href)
    fixed = {
      "role"                    => "menuitem",
      "tabindex"                => "-1",
      "data-opal-ui"            => "dropdown-link",
      "data-opal-dropdown-item" => "",
    }
    if disabled
      fixed["aria-disabled"] = "true"
    else
      fixed["href"] = href
    end
    attrs = component_attributes(DROPDOWN_ITEM, class_name, attributes, fixed)
    LF::LiveView::HTML.rendered(%(<a#{attrs}>#{content}</a>))
  end
end
