module LF::UI
  DIALOG_BASE       = "fixed inset-0 m-0 h-full max-h-none w-full max-w-none overflow-y-auto border-0 bg-transparent p-4 text-slate-950 dark:text-slate-50"
  DIALOG_POSITIONER = "flex min-h-full items-center justify-center py-6"
  DIALOG_PANEL      = "w-full max-w-lg overflow-hidden rounded-2xl border border-slate-200 bg-white text-slate-950 shadow-xl dark:border-slate-800 dark:bg-slate-900 dark:text-slate-50"

  # Renders a native modal dialog whose open state remains owned by the
  # application view. `hook_script_tag` or `hook_script_link` must load before
  # the LiveView client so the OpalDialog hook can synchronize native top-layer
  # state and deliver Escape/backdrop close requests.
  def dialog(
    content,
    *,
    id : String,
    open : Bool,
    labelled_by : String,
    close_event : String,
    described_by : String? = nil,
    return_focus : String? = nil,
    close_on_escape : Bool = true,
    close_on_backdrop : Bool = true,
    class_name : String? = nil,
    panel_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_id!(labelled_by)
    described_by.try { |value| validate_id!(value) }
    return_focus.try { |value| validate_id!(value) }
    validate_event!(close_event, "UI dialog close event")

    fixed = {
      "id"                              => id,
      "role"                            => "dialog",
      "aria-modal"                      => "true",
      "aria-labelledby"                 => labelled_by,
      "data-opal-ui"                    => "dialog",
      "phx-hook"                        => "OpalDialog",
      "data-opal-dialog-open"           => open.to_s,
      "data-opal-dialog-close-event"    => close_event,
      "data-opal-dialog-close-escape"   => close_on_escape.to_s,
      "data-opal-dialog-close-backdrop" => close_on_backdrop.to_s,
    }
    described_by.try { |value| fixed["aria-describedby"] = value }
    return_focus.try { |value| fixed["data-opal-dialog-return-focus"] = value }
    attrs = component_attributes(DIALOG_BASE, class_name, attributes, fixed)
    panel_attrs = component_attributes(
      DIALOG_PANEL,
      panel_class_name,
      EMPTY_ATTRIBUTES,
      {"data-opal-ui" => "dialog-panel"}
    )

    LF::LiveView::HTML.rendered(<<-HTML)
      <dialog#{attrs}>
        <div class="#{DIALOG_POSITIONER}" data-opal-ui="dialog-positioner">
          <section#{panel_attrs}>#{content}</section>
        </div>
      </dialog>
    HTML
  end

  def dialog_header(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "border-b border-slate-200 px-6 py-5 dark:border-slate-800",
      class_name,
      attributes,
      {"data-opal-ui" => "dialog-header"}
    )
    LF::LiveView::HTML.rendered(%(<header#{attrs}>#{content}</header>))
  end

  def dialog_title(
    content,
    *,
    id : String,
    level : Int32 = 2,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    unless 1 <= level <= 6
      raise ArgumentError.new("UI dialog title level must be between 1 and 6")
    end
    attrs = component_attributes(
      "text-lg font-semibold tracking-tight",
      class_name,
      attributes,
      {"id" => id, "data-opal-ui" => "dialog-title"}
    )
    case level
    when 1
      LF::LiveView::HTML.rendered(%(<h1#{attrs}>#{content}</h1>))
    when 2
      LF::LiveView::HTML.rendered(%(<h2#{attrs}>#{content}</h2>))
    when 3
      LF::LiveView::HTML.rendered(%(<h3#{attrs}>#{content}</h3>))
    when 4
      LF::LiveView::HTML.rendered(%(<h4#{attrs}>#{content}</h4>))
    when 5
      LF::LiveView::HTML.rendered(%(<h5#{attrs}>#{content}</h5>))
    else
      LF::LiveView::HTML.rendered(%(<h6#{attrs}>#{content}</h6>))
    end
  end

  def dialog_description(
    content,
    *,
    id : String,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    attrs = component_attributes(
      "mt-1 text-sm leading-6 text-slate-600 dark:text-slate-400",
      class_name,
      attributes,
      {"id" => id, "data-opal-ui" => "dialog-description"}
    )
    LF::LiveView::HTML.rendered(%(<p#{attrs}>#{content}</p>))
  end

  def dialog_body(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "px-6 py-5",
      class_name,
      attributes,
      {"data-opal-ui" => "dialog-body"}
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def dialog_footer(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "flex flex-wrap items-center justify-end gap-3 border-t border-slate-200 bg-slate-50 px-6 py-4 dark:border-slate-800 dark:bg-slate-950/40",
      class_name,
      attributes,
      {"data-opal-ui" => "dialog-footer"}
    )
    LF::LiveView::HTML.rendered(%(<footer#{attrs}>#{content}</footer>))
  end
end
