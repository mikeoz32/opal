module LF::UI
  enum DataTableColumnAlignment
    Start
    Center
    End
  end

  enum DataTableSortDirection
    Ascending
    Descending

    def parameter_value : String
      ascending? ? "asc" : "desc"
    end

    def aria_value : String
      ascending? ? "ascending" : "descending"
    end

    def reverse : self
      ascending? ? Descending : Ascending
    end
  end

  # One typed column in a server-driven data table. The render block must
  # return trusted structural markup; normal values should be interpolated
  # through `LF::LiveView::HTML.rendered` so they remain escaped.
  struct DataTableColumn(RowType)
    getter key : String
    getter label : String
    getter alignment : DataTableColumnAlignment
    getter? sortable : Bool
    getter? row_header : Bool
    getter header_class_name : String?
    getter cell_class_name : String?

    @renderer : Proc(RowType, LF::LiveView::Rendered)

    def initialize(
      @key : String,
      @label : String,
      *,
      @alignment : DataTableColumnAlignment = DataTableColumnAlignment::Start,
      @sortable : Bool = false,
      @row_header : Bool = false,
      @header_class_name : String? = nil,
      @cell_class_name : String? = nil,
      &@renderer : RowType -> LF::LiveView::Rendered
    )
      if @key.blank? || @key.each_char.any?(&.control?)
        raise ArgumentError.new("UI data table column key must not be blank or contain control characters")
      end
      if @label.blank?
        raise ArgumentError.new("UI data table column label must not be blank")
      end
    end

    def render(row : RowType) : LF::LiveView::Rendered
      @renderer.call(row)
    end
  end

  # Repository-agnostic paging metadata. It can be constructed directly from
  # an `LF::Data::Page(T)` without making the optional UI package depend on
  # the Data package.
  struct DataTablePageInfo
    getter number : Int64
    getter page_size : Int64
    getter total_items : Int64

    def initialize(number : Int, page_size : Int, total_items : Int)
      @number = number.to_i64
      @page_size = page_size.to_i64
      @total_items = total_items.to_i64

      raise ArgumentError.new("UI data table page number must be positive") unless @number.positive?
      raise ArgumentError.new("UI data table page size must be positive") unless @page_size.positive?
      raise ArgumentError.new("UI data table total items must not be negative") if @total_items.negative?
    end

    def first_item : Int64
      return 0_i64 if total_items.zero?

      offset = (number.to_i128 - 1_i128) * page_size
      return 0_i64 if offset >= total_items

      (offset + 1_i128).to_i64
    end

    def last_item : Int64
      return 0_i64 if first_item.zero?

      Math.min(number.to_i128 * page_size, total_items.to_i128).to_i64
    end
  end

  # Renders a typed, server-driven data table. Querying, sorting, pagination,
  # selection, and error/loading state remain owned by the application view.
  def data_table(
    rows : Array(RowType),
    columns : Array(DataTableColumn(RowType)),
    *,
    id : String,
    caption : String,
    row_key : Proc(RowType, String),
    sort_key : String? = nil,
    sort_direction : DataTableSortDirection = DataTableSortDirection::Ascending,
    sort_event : String? = nil,
    selected_keys : Set(String) = Set(String).new,
    select_event : String? = nil,
    select_all_event : String? = nil,
    selection_label : Proc(RowType, String)? = nil,
    bulk_actions : LF::LiveView::Rendered? = nil,
    page_info : DataTablePageInfo? = nil,
    pagination : LF::LiveView::Rendered? = nil,
    loading : Bool = false,
    loading_message : String = "Loading rows…",
    empty_message : String = "No rows found.",
    error_message : String? = nil,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered forall RowType
    validate_data_table!(
      id,
      caption,
      columns,
      sort_key,
      sort_event,
      select_event,
      select_all_event,
      loading_message,
      empty_message,
      error_message
    )

    row_keys = data_table_row_keys(rows, id, row_key)
    keyed_rows = data_table_rows(rows, row_keys, columns, id, selected_keys, select_event, selection_label)
    column_count = columns.size + (select_event ? 1 : 0)
    body_content = data_table_body_content(
      keyed_rows,
      rows.empty?,
      column_count,
      loading,
      loading_message,
      empty_message,
      error_message
    )
    head = data_table_head(
      row_keys,
      columns,
      sort_key,
      sort_direction,
      sort_event,
      selected_keys,
      select_event,
      select_all_event
    )
    table_attributes = {
      "id"        => "#{id}-table",
      "aria-busy" => loading.to_s,
    }
    body = table_body(body_content, attributes: {"id" => "#{id}-body"})
    rendered_table = table(
      LF::LiveView::HTML.rendered(%(#{head}#{body})),
      caption: caption,
      attributes: table_attributes
    )
    toolbar = data_table_toolbar(id, selected_keys, select_event, bulk_actions)
    footer = data_table_footer(id, page_info, pagination)
    attrs = component_attributes(
      "space-y-3",
      class_name,
      attributes,
      {
        "id"                => id,
        "data-opal-ui"      => "data-table",
        "data-opal-loading" => loading.to_s,
      }
    )

    LF::LiveView::HTML.rendered(<<-HTML)
      <section#{attrs}>#{toolbar}#{rendered_table}#{footer}</section>
    HTML
  end

  private def validate_data_table!(
    id : String,
    caption : String,
    columns : Array(DataTableColumn(RowType)),
    sort_key : String?,
    sort_event : String?,
    select_event : String?,
    select_all_event : String?,
    loading_message : String,
    empty_message : String,
    error_message : String?,
  ) : Nil forall RowType
    validate_id!(id)
    raise ArgumentError.new("UI data table caption must not be blank") if caption.blank?
    raise ArgumentError.new("UI data table must have at least one column") if columns.empty?
    if columns.map(&.key).uniq.size != columns.size
      raise ArgumentError.new("UI data table column keys must be unique")
    end
    if columns.count(&.row_header?) > 1
      raise ArgumentError.new("UI data table may have at most one row header column")
    end
    if columns.any?(&.sortable?)
      unless sort_event
        raise ArgumentError.new("UI data table sortable columns require a sort event")
      end
      validate_event!(sort_event, "UI data table sort event")
    elsif sort_key
      raise ArgumentError.new("UI data table sort key must reference a sortable column")
    end
    if sort_key && !columns.any? { |column| column.sortable? && column.key == sort_key }
      raise ArgumentError.new("UI data table sort key must reference a sortable column")
    end
    if select_event.nil? != select_all_event.nil?
      raise ArgumentError.new("UI data table row and select-all events must be provided together")
    end
    select_event.try { |event| validate_event!(event, "UI data table row selection event") }
    select_all_event.try { |event| validate_event!(event, "UI data table select-all event") }
    raise ArgumentError.new("UI data table loading message must not be blank") if loading_message.blank?
    raise ArgumentError.new("UI data table empty message must not be blank") if empty_message.blank?
    if error_message.try(&.blank?)
      raise ArgumentError.new("UI data table error message must not be blank")
    end
  end

  private def data_table_head(
    row_keys : Array(String),
    columns : Array(DataTableColumn(RowType)),
    sort_key : String?,
    sort_direction : DataTableSortDirection,
    sort_event : String?,
    selected_keys : Set(String),
    select_event : String?,
    select_all_event : String?,
  ) : LF::LiveView::Rendered forall RowType
    headers = String.build do |html|
      if select_event && select_all_event
        selected_count = row_keys.count { |key| selected_keys.includes?(key) }
        state = if !row_keys.empty? && selected_count == row_keys.size
                  "true"
                elsif selected_count.positive?
                  "mixed"
                else
                  "false"
                end
        label = state == "true" ? "Deselect all visible rows" : "Select all visible rows"
        control = data_table_selection_control(label, state, select_all_event, disabled: row_keys.empty?)
        html << table_header(
          control,
          class_name: "w-12 text-center"
        ).to_html
      end

      columns.each do |column|
        active = sort_key == column.key
        header_attributes = {"data-column" => column.key}
        header_attributes["aria-sort"] = sort_direction.aria_value if active
        content = if column.sortable?
                    data_table_sort_control(column, active, sort_direction, sort_event.not_nil!)
                  else
                    LF::LiveView::HTML.rendered(%(#{column.label}))
                  end
        html << table_header(
          content,
          class_name: "#{data_table_alignment_classes(column.alignment)} #{column.header_class_name}",
          attributes: header_attributes
        ).to_html
      end
    end
    table_head(table_row(LF::LiveView::HTML.raw(headers)))
  end

  private def data_table_rows(
    rows : Array(RowType),
    row_keys : Array(String),
    columns : Array(DataTableColumn(RowType)),
    id : String,
    selected_keys : Set(String),
    select_event : String?,
    selection_label : Proc(RowType, String)?,
  ) : LF::LiveView::KeyedContent forall RowType
    LF::LiveView::HTML.keyed(rows.zip(row_keys)) do |entry|
      row, key = entry
      selected = selected_keys.includes?(key)
      cells = String.build do |html|
        if event = select_event
          label_text = selection_label.try(&.call(row)) || key
          label = selected ? "Deselect #{label_text}" : "Select #{label_text}"
          control = data_table_selection_control(label, selected.to_s, event, key)
          html << table_cell(
            control,
            class_name: "w-12 text-center"
          ).to_html
        end
        columns.each do |column|
          html << data_table_cell(column, row).to_html
        end
      end
      attrs = component_attributes(
        "transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/60 #{selected ? "bg-blue-50/70 dark:bg-blue-950/30" : ""}",
        nil,
        EMPTY_ATTRIBUTES,
        {
          "id"            => "#{id}-row-#{key}",
          "data-opal-ui"  => "data-table-row",
          "data-row-key"  => key,
          "data-selected" => selected.to_s,
        }
      )
      {key, LF::LiveView::HTML.rendered(%(<tr#{attrs}>#{LF::LiveView::HTML.raw(cells)}</tr>))}
    end
  end

  private def data_table_cell(column : DataTableColumn(RowType), row : RowType) : LF::LiveView::Rendered forall RowType
    attrs = component_attributes(
      "px-4 py-3 text-slate-700 dark:text-slate-300 #{data_table_alignment_classes(column.alignment)}",
      column.cell_class_name,
      EMPTY_ATTRIBUTES,
      {
        "data-opal-ui" => "data-table-cell",
        "data-column"  => column.key,
      }
    )
    content = column.render(row)
    if column.row_header?
      LF::LiveView::HTML.rendered(%(<th#{attrs} scope="row">#{content}</th>))
    else
      LF::LiveView::HTML.rendered(%(<td#{attrs}>#{content}</td>))
    end
  end

  private def data_table_sort_control(
    column : DataTableColumn(RowType),
    active : Bool,
    direction : DataTableSortDirection,
    event : String,
  ) : LF::LiveView::Rendered forall RowType
    next_direction = active ? direction.reverse : DataTableSortDirection::Ascending
    fixed = {
      "type"                => "button",
      "phx-click"           => event,
      "phx-value-sort"      => column.key,
      "phx-value-direction" => next_direction.parameter_value,
      "data-opal-ui"        => "data-table-sort",
    }
    attrs = component_attributes(
      "inline-flex min-h-9 w-full items-center gap-2 rounded-md font-[inherit] font-semibold text-inherit outline-none hover:text-blue-700 focus-visible:ring-2 focus-visible:ring-blue-600 dark:hover:text-blue-300 #{data_table_justify_classes(column.alignment)}",
      nil,
      EMPTY_ATTRIBUTES,
      fixed
    )
    indicator = if active
                  direction.ascending? ? "↑" : "↓"
                else
                  "↕"
                end
    LF::LiveView::HTML.rendered(
      %(<button#{attrs}><span>#{column.label}</span><span aria-hidden="true">#{indicator}</span></button>)
    )
  end

  private def data_table_selection_control(
    label : String,
    state : String,
    event : String,
    row_key : String? = nil,
    disabled : Bool = false,
  ) : LF::LiveView::Rendered
    fixed = {
      "type"             => "button",
      "role"             => "checkbox",
      "aria-label"       => label,
      "aria-checked"     => state,
      "phx-click"        => event,
      "data-opal-ui"     => "data-table-selection",
      "data-check-state" => state,
    }
    fixed["phx-value-row"] = row_key if row_key
    fixed["aria-disabled"] = "true" if disabled
    booleans = disabled ? ["disabled"] : [] of String
    attrs = component_attributes(
      "inline-flex size-5 cursor-pointer items-center justify-center rounded border text-xs font-bold outline-none focus-visible:ring-2 focus-visible:ring-blue-600 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:focus-visible:ring-offset-slate-950 #{data_table_selection_classes(state)}",
      nil,
      EMPTY_ATTRIBUTES,
      fixed,
      booleans
    )
    mark = case state
           when "true"  then "✓"
           when "mixed" then "−"
           else              ""
           end
    LF::LiveView::HTML.rendered(%(<button#{attrs}><span aria-hidden="true">#{mark}</span></button>))
  end

  private def data_table_body_content(
    rows : LF::LiveView::KeyedContent,
    empty : Bool,
    column_count : Int32,
    loading : Bool,
    loading_message : String,
    empty_message : String,
    error_message : String?,
  )
    if error_message
      data_table_state_row(error_message, column_count, "alert", "error")
    elsif loading && empty
      data_table_state_row(loading_message, column_count, "status", "loading")
    elsif empty
      data_table_state_row(empty_message, column_count, "status", "empty")
    else
      rows
    end
  end

  private def data_table_state_row(
    message : String,
    column_count : Int32,
    role : String,
    state : String,
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "px-4 py-10 text-center text-sm text-slate-600 dark:text-slate-400",
      nil,
      EMPTY_ATTRIBUTES,
      {
        "colspan"      => column_count.to_s,
        "data-opal-ui" => "data-table-state",
        "data-state"   => state,
      }
    )
    LF::LiveView::HTML.rendered(
      %(<tr><td#{attrs}><span role="#{role}" aria-live="polite">#{message}</span></td></tr>)
    )
  end

  private def data_table_toolbar(
    id : String,
    selected_keys : Set(String),
    select_event : String?,
    bulk_actions : LF::LiveView::Rendered?,
  ) : LF::LiveView::Rendered
    return LF::LiveView::Rendered.opaque("") unless select_event

    actions = selected_keys.empty? ? LF::LiveView::Rendered.opaque("") : (bulk_actions || LF::LiveView::Rendered.opaque(""))
    LF::LiveView::HTML.rendered(<<-HTML)
      <div class="flex min-h-10 flex-wrap items-center justify-between gap-3" data-opal-ui="data-table-toolbar">
        <p id="#{id}-selection-status" class="text-sm text-slate-600 dark:text-slate-400" role="status" aria-live="polite">#{selected_keys.size} selected</p>
        <div class="flex flex-wrap items-center gap-2">#{actions}</div>
      </div>
    HTML
  end

  private def data_table_footer(
    id : String,
    page_info : DataTablePageInfo?,
    pagination : LF::LiveView::Rendered?,
  ) : LF::LiveView::Rendered
    return LF::LiveView::Rendered.opaque("") unless page_info || pagination

    summary = if page = page_info
                if page.first_item.zero?
                  "Showing 0 of #{page.total_items}"
                else
                  "Showing #{page.first_item}–#{page.last_item} of #{page.total_items}"
                end
              else
                ""
              end
    navigation = pagination || LF::LiveView::Rendered.opaque("")
    LF::LiveView::HTML.rendered(<<-HTML)
      <footer class="flex flex-wrap items-center justify-between gap-3" data-opal-ui="data-table-footer">
        <p id="#{id}-page-summary" class="text-sm text-slate-600 dark:text-slate-400">#{summary}</p>
        <div class="min-w-fit">#{navigation}</div>
      </footer>
    HTML
  end

  private def data_table_row_keys(
    rows : Array(RowType),
    id : String,
    row_key : Proc(RowType, String),
  ) : Array(String) forall RowType
    keys = rows.map do |row|
      key = row_key.call(row)
      validate_data_table_row_key!(id, key)
      key
    end
    if keys.uniq.size != keys.size
      raise ArgumentError.new("UI data table row keys must be unique")
    end
    keys
  end

  private def validate_data_table_row_key!(id : String, key : String) : Nil
    if key.blank? || key.each_char.any?(&.whitespace?)
      raise ArgumentError.new("UI data table row key must not be blank or contain whitespace")
    end
    validate_id!("#{id}-row-#{key}")
  end

  private def data_table_alignment_classes(alignment : DataTableColumnAlignment) : String
    case alignment
    when .start?  then "text-left"
    when .center? then "text-center"
    when .end?    then "text-right"
    else               raise "Unsupported UI data table column alignment"
    end
  end

  private def data_table_justify_classes(alignment : DataTableColumnAlignment) : String
    case alignment
    when .start?  then "justify-start text-left"
    when .center? then "justify-center text-center"
    when .end?    then "justify-end text-right"
    else               raise "Unsupported UI data table column alignment"
    end
  end

  private def data_table_selection_classes(state : String) : String
    case state
    when "true", "mixed"
      "border-blue-600 bg-blue-600 text-white dark:border-blue-500 dark:bg-blue-500"
    else
      "border-slate-300 bg-white text-transparent hover:border-blue-500 dark:border-slate-700 dark:bg-slate-950"
    end
  end
end
