module LF::UI
  def badge(
    content,
    *,
    tone : Tone = Tone::Neutral,
    size : Size = Size::Medium,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    fixed = {
      "data-opal-ui" => "badge",
      "data-ui-tone" => tone_name(tone),
      "data-ui-size" => size_name(size),
    }
    attrs = component_attributes(
      "inline-flex items-center rounded-full font-medium ring-1 ring-inset #{badge_size_classes(size)} #{badge_tone_classes(tone)}",
      class_name,
      attributes,
      fixed
    )
    LF::LiveView::HTML.rendered(%(<span#{attrs}>#{content}</span>))
  end

  def alert(
    content,
    *,
    title : String? = nil,
    tone : Tone = Tone::Neutral,
    live : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    fixed = {
      "data-opal-ui" => "alert",
      "data-ui-tone" => tone_name(tone),
    }
    if live
      fixed["role"] = tone == Tone::Danger ? "alert" : "status"
      fixed["aria-live"] = tone == Tone::Danger ? "assertive" : "polite"
    end
    attrs = component_attributes(
      "rounded-xl border p-4 text-sm #{alert_tone_classes(tone)}",
      class_name,
      attributes,
      fixed
    )
    heading = if title
                LF::LiveView::HTML.rendered(%(<h3 class="mb-1 font-semibold">#{title}</h3>))
              else
                LF::LiveView::Rendered.opaque("")
              end
    LF::LiveView::HTML.rendered(<<-HTML)
      <div#{attrs}>
        #{heading}<div class="leading-6">#{content}</div>
      </div>
    HTML
  end

  private def badge_size_classes(size : Size) : String
    case size
    when .small?  then "px-2 py-0.5 text-xs"
    when .medium? then "px-2.5 py-1 text-xs"
    when .large?  then "px-3 py-1.5 text-sm"
    else               raise "Unsupported UI badge size"
    end
  end

  private def badge_tone_classes(tone : Tone) : String
    case tone
    when .neutral? then "bg-slate-100 text-slate-700 ring-slate-300 dark:bg-slate-800 dark:text-slate-200 dark:ring-slate-700"
    when .primary? then "bg-blue-50 text-blue-700 ring-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:ring-blue-800"
    when .success? then "bg-emerald-50 text-emerald-700 ring-emerald-200 dark:bg-emerald-950 dark:text-emerald-300 dark:ring-emerald-800"
    when .warning? then "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:ring-amber-800"
    when .danger?  then "bg-red-50 text-red-700 ring-red-200 dark:bg-red-950 dark:text-red-300 dark:ring-red-800"
    else                raise "Unsupported UI badge tone"
    end
  end

  private def alert_tone_classes(tone : Tone) : String
    case tone
    when .neutral? then "border-slate-200 bg-slate-50 text-slate-800 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-200"
    when .primary? then "border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200"
    when .success? then "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
    when .warning? then "border-amber-200 bg-amber-50 text-amber-950 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
    when .danger?  then "border-red-200 bg-red-50 text-red-900 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
    else                raise "Unsupported UI alert tone"
    end
  end
end
