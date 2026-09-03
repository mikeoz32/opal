module LF::UI
  def card(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "overflow-hidden rounded-2xl border border-slate-200 bg-white text-slate-950 shadow-sm dark:border-slate-800 dark:bg-slate-900 dark:text-slate-50",
      class_name,
      attributes,
      {"data-opal-ui" => "card"}
    )
    LF::LiveView::HTML.rendered(%(<section#{attrs}>#{content}</section>))
  end

  def card_header(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "border-b border-slate-200 px-6 py-5 dark:border-slate-800",
      class_name,
      attributes,
      {"data-opal-ui" => "card-header"}
    )
    LF::LiveView::HTML.rendered(%(<header#{attrs}>#{content}</header>))
  end

  def card_title(
    content,
    *,
    level : Int32 = 2,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    unless 1 <= level <= 6
      raise ArgumentError.new("UI card title level must be between 1 and 6")
    end
    attrs = component_attributes(
      "text-lg font-semibold tracking-tight",
      class_name,
      attributes,
      {"data-opal-ui" => "card-title"}
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

  def card_description(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "mt-1 text-sm leading-6 text-slate-600 dark:text-slate-400",
      class_name,
      attributes,
      {"data-opal-ui" => "card-description"}
    )
    LF::LiveView::HTML.rendered(%(<p#{attrs}>#{content}</p>))
  end

  def card_body(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "px-6 py-5",
      class_name,
      attributes,
      {"data-opal-ui" => "card-body"}
    )
    LF::LiveView::HTML.rendered(%(<div#{attrs}>#{content}</div>))
  end

  def card_footer(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "flex flex-wrap items-center gap-3 border-t border-slate-200 bg-slate-50 px-6 py-4 dark:border-slate-800 dark:bg-slate-950/40",
      class_name,
      attributes,
      {"data-opal-ui" => "card-footer"}
    )
    LF::LiveView::HTML.rendered(%(<footer#{attrs}>#{content}</footer>))
  end
end
