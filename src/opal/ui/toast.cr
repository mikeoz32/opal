module LF::UI
  def toast_region(
    content,
    *,
    id : String,
    label : String = "Notifications",
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    raise ArgumentError.new("UI toast region label must not be blank") if label.blank?
    attrs = component_attributes(
      "pointer-events-none fixed inset-x-4 top-4 z-[60] ml-auto flex max-w-sm flex-col gap-3 sm:left-auto sm:w-full",
      class_name,
      attributes,
      {
        "id"            => id,
        "role"          => "region",
        "aria-label"    => label,
        "aria-live"     => "polite",
        "aria-relevant" => "additions text",
        "data-opal-ui"  => "toast-region",
      }
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def toast(
    content,
    *,
    id : String,
    title : String? = nil,
    tone : Tone = Tone::Neutral,
    dismiss_event : String? = nil,
    auto_dismiss_ms : Int32? = nil,
    dismiss_label : String = "Dismiss notification",
    return_focus : String? = nil,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    return_focus.try { |value| validate_id!(value) }
    dismiss_event.try { |event| validate_event!(event, "UI toast dismiss event") }
    if auto_dismiss_ms
      if auto_dismiss_ms <= 0
        raise ArgumentError.new("UI toast auto dismiss duration must be greater than zero")
      end
      unless dismiss_event
        raise ArgumentError.new("UI toast auto dismiss requires a dismiss event")
      end
    end
    if dismiss_event && dismiss_label.blank?
      raise ArgumentError.new("UI toast dismiss label must not be blank")
    end
    if return_focus && dismiss_event.nil?
      raise ArgumentError.new("UI toast return focus requires a dismiss event")
    end

    fixed = {
      "id"           => id,
      "role"         => tone == Tone::Danger ? "alert" : "status",
      "data-opal-ui" => "toast",
      "data-ui-tone" => tone_name(tone),
    }
    if dismiss_event
      fixed["data-opal-hook"] = "OpalToast"
      fixed["data-opal-toast-dismiss-event"] = dismiss_event
      auto_dismiss_ms.try { |duration| fixed["data-opal-toast-duration"] = duration.to_s }
      return_focus.try { |value| fixed["data-opal-toast-return-focus"] = value }
    end
    attrs = component_attributes(
      "pointer-events-auto flex items-start gap-3 rounded-xl border p-4 shadow-lg #{toast_tone_classes(tone)}",
      class_name,
      attributes,
      fixed
    )
    heading = title ? %(<h3 class="font-semibold">#{LF::LiveView::HTML.escape(title)}</h3>) : ""
    dismiss = if dismiss_event
                <<-HTML
                  <button type="button" class="-m-1 ml-auto inline-flex shrink-0 cursor-pointer rounded-lg p-1.5 opacity-70 transition-opacity hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current" data-opal-ui="toast-dismiss" data-opal-toast-dismiss aria-label="#{LF::LiveView::HTML.escape(dismiss_label)}">
                    <span aria-hidden="true">&times;</span>
                  </button>
                HTML
              else
                ""
              end
    LF::LiveView::HTML.rendered(<<-HTML)
      <div#{attrs}>
        <div class="min-w-0 flex-1">#{LF::LiveView::HTML.raw(heading)}<div class="text-sm leading-6">#{content}</div></div>
        #{LF::LiveView::HTML.raw(dismiss)}
      </div>
    HTML
  end

  private def toast_tone_classes(tone : Tone) : String
    case tone
    when .neutral? then "border-slate-200 bg-white text-slate-900 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-100"
    when .primary? then "border-blue-200 bg-blue-50 text-blue-950 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-100"
    when .success? then "border-emerald-200 bg-emerald-50 text-emerald-950 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-100"
    when .warning? then "border-amber-200 bg-amber-50 text-amber-950 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
    when .danger?  then "border-red-200 bg-red-50 text-red-950 dark:border-red-900 dark:bg-red-950 dark:text-red-100"
    else                raise "Unsupported UI toast tone"
    end
  end
end
