module LF::UI
  def table(
    content,
    *,
    caption : String? = nil,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "w-full border-separate border-spacing-0 text-left text-sm",
      class_name,
      attributes,
      {"data-opal-ui" => "table"}
    )
    caption_markup = if caption
                       LF::LiveView::HTML.rendered(%(<caption class="sr-only">#{caption}</caption>))
                     else
                       LF::LiveView::Rendered.opaque("")
                     end
    LF::LiveView::HTML.rendered(<<-HTML)
      <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800" data-opal-ui="table-container">
        <table#{attrs}>#{caption_markup}#{content}</table>
      </div>
    HTML
  end

  def table_head(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "bg-slate-50 text-slate-700 dark:bg-slate-950/60 dark:text-slate-300",
      class_name,
      attributes,
      {"data-opal-ui" => "table-head"}
    )
    LF::LiveView::HTML.rendered(%(<thead#{attrs}>#{content}</thead>))
  end

  def table_body(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "divide-y divide-slate-200 bg-white dark:divide-slate-800 dark:bg-slate-900",
      class_name,
      attributes,
      {"data-opal-ui" => "table-body"}
    )
    LF::LiveView::HTML.rendered(%(<tbody#{attrs}>#{content}</tbody>))
  end

  def table_row(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/60",
      class_name,
      attributes,
      {"data-opal-ui" => "table-row"}
    )
    LF::LiveView::HTML.rendered(%(<tr#{attrs}>#{content}</tr>))
  end

  def table_header(
    content,
    *,
    scope : String = "col",
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    unless {"col", "colgroup", "row", "rowgroup"}.includes?(scope)
      raise ArgumentError.new("UI table header scope is invalid")
    end
    attrs = component_attributes(
      "border-b border-slate-200 px-4 py-3 font-semibold dark:border-slate-800",
      class_name,
      attributes,
      {"scope" => scope, "data-opal-ui" => "table-header"}
    )
    LF::LiveView::HTML.rendered(%(<th#{attrs}>#{content}</th>))
  end

  def table_cell(
    content,
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "px-4 py-3 text-slate-700 dark:text-slate-300",
      class_name,
      attributes,
      {"data-opal-ui" => "table-cell"}
    )
    LF::LiveView::HTML.rendered(%(<td#{attrs}>#{content}</td>))
  end
end
