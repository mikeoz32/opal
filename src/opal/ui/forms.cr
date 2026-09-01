module LF::UI
  FIELD_LABEL_CLASSES  = "block text-sm font-medium text-slate-800 dark:text-slate-200"
  FIELD_HINT_CLASSES   = "mt-1.5 text-sm text-slate-600 dark:text-slate-400"
  FIELD_ERROR_CLASSES  = "mt-1.5 text-sm font-medium text-red-600 dark:text-red-400"
  CONTROL_BASE_CLASSES = "mt-1.5 block w-full rounded-lg border bg-white px-3 py-2 font-[inherit] text-sm text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:ring-2 disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-500 dark:bg-slate-950 dark:text-slate-50 dark:disabled:bg-slate-900"
  CHOICE_BASE_CLASSES  = "size-4 shrink-0 accent-blue-600 border-slate-300 text-blue-600 focus:ring-2 focus:ring-blue-600 disabled:cursor-not-allowed disabled:opacity-50 dark:border-slate-700 dark:bg-slate-950"
  INPUT_TYPES          = Set{"text", "email", "password", "search", "url", "tel", "number", "date", "time", "datetime-local"}

  # Wraps an application-owned control with a label and help/error text.
  # The control should reference the generated `<id>-hint` and `<id>-error`
  # ids through `aria-describedby` when those values are present.
  def field(
    label : String,
    control,
    *,
    id : String,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    render_field(label, control, id, hint, error, required, class_name, attributes)
  end

  def input(
    label : String,
    *,
    id : String,
    name : String,
    value : String = "",
    type : String = "text",
    placeholder : String? = nil,
    autocomplete : String? = nil,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    disabled : Bool = false,
    readonly : Bool = false,
    class_name : String? = nil,
    input_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_name!(name)
    unless INPUT_TYPES.includes?(type)
      raise ArgumentError.new("Unsupported UI input type '#{type}'")
    end

    fixed = {
      "id"           => id,
      "name"         => name,
      "type"         => type,
      "value"        => value,
      "data-opal-ui" => "input",
    }
    fixed["placeholder"] = placeholder if placeholder
    fixed["autocomplete"] = autocomplete if autocomplete
    add_accessibility_attributes(fixed, id, hint, error, required)
    booleans = [] of String
    booleans << "required" if required
    booleans << "disabled" if disabled
    booleans << "readonly" if readonly
    control_attrs = component_attributes(
      "#{CONTROL_BASE_CLASSES} #{control_state_classes(error)}",
      input_class_name,
      attributes,
      fixed,
      booleans
    )
    control = LF::LiveView::HTML.rendered(%(<input#{control_attrs}>))
    render_field(label, control, id, hint, error, required, class_name, EMPTY_ATTRIBUTES)
  end

  def textarea(
    label : String,
    *,
    id : String,
    name : String,
    value : String = "",
    rows : Int32 = 4,
    placeholder : String? = nil,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    disabled : Bool = false,
    readonly : Bool = false,
    class_name : String? = nil,
    input_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_name!(name)
    raise ArgumentError.new("UI textarea rows must be positive") unless rows.positive?

    fixed = {
      "id"           => id,
      "name"         => name,
      "rows"         => rows.to_s,
      "data-opal-ui" => "textarea",
    }
    fixed["placeholder"] = placeholder if placeholder
    add_accessibility_attributes(fixed, id, hint, error, required)
    booleans = [] of String
    booleans << "required" if required
    booleans << "disabled" if disabled
    booleans << "readonly" if readonly
    control_attrs = component_attributes(
      "#{CONTROL_BASE_CLASSES} min-h-24 resize-y #{control_state_classes(error)}",
      input_class_name,
      attributes,
      fixed,
      booleans
    )
    control = LF::LiveView::HTML.rendered(%(<textarea#{control_attrs}>#{value}</textarea>))
    render_field(label, control, id, hint, error, required, class_name, EMPTY_ATTRIBUTES)
  end

  def select(
    label : String,
    options : Enumerable(SelectOption),
    *,
    id : String,
    name : String,
    selected : String? = nil,
    prompt : String? = nil,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    disabled : Bool = false,
    class_name : String? = nil,
    input_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_name!(name)

    fixed = {
      "id"           => id,
      "name"         => name,
      "data-opal-ui" => "select",
    }
    add_accessibility_attributes(fixed, id, hint, error, required)
    booleans = [] of String
    booleans << "required" if required
    booleans << "disabled" if disabled
    control_attrs = component_attributes(
      "#{CONTROL_BASE_CLASSES} appearance-none pr-10 #{control_state_classes(error)}",
      input_class_name,
      attributes,
      fixed,
      booleans
    )
    option_markup = select_options(options, selected, prompt)
    control = LF::LiveView::HTML.rendered(%(<select#{control_attrs}>#{option_markup}</select>))
    render_field(label, control, id, hint, error, required, class_name, EMPTY_ATTRIBUTES)
  end

  def checkbox(
    label : String,
    *,
    id : String,
    name : String,
    value : String = "1",
    checked : Bool = false,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    disabled : Bool = false,
    class_name : String? = nil,
    input_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    choice_field(
      "checkbox",
      label,
      id: id,
      name: name,
      value: value,
      checked: checked,
      hint: hint,
      error: error,
      required: required,
      disabled: disabled,
      class_name: class_name,
      input_class_name: input_class_name,
      attributes: attributes
    )
  end

  def radio(
    label : String,
    *,
    id : String,
    name : String,
    value : String,
    checked : Bool = false,
    hint : String? = nil,
    error : String? = nil,
    required : Bool = false,
    disabled : Bool = false,
    class_name : String? = nil,
    input_class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    choice_field(
      "radio",
      label,
      id: id,
      name: name,
      value: value,
      checked: checked,
      hint: hint,
      error: error,
      required: required,
      disabled: disabled,
      class_name: class_name,
      input_class_name: input_class_name,
      attributes: attributes
    )
  end

  def switch(
    label : String,
    *,
    id : String,
    checked : Bool = false,
    disabled : Bool = false,
    size : Size = Size::Medium,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_id!(id)
    fixed = {
      "id"           => id,
      "type"         => "button",
      "role"         => "switch",
      "aria-checked" => checked.to_s,
      "data-opal-ui" => "switch",
      "data-ui-size" => size_name(size),
    }
    booleans = disabled ? ["disabled"] : [] of String
    attrs = component_attributes(
      "inline-flex cursor-pointer items-center justify-self-start gap-3 rounded-lg border-0 bg-transparent p-0 font-[inherit] text-left text-sm font-medium text-slate-800 outline-none focus-visible:ring-2 focus-visible:ring-blue-600 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:text-slate-200 dark:focus-visible:ring-offset-slate-950",
      class_name,
      attributes,
      fixed,
      booleans
    )
    track_classes = switch_track_classes(size, checked)
    thumb_classes = switch_thumb_classes(size, checked)
    LF::LiveView::HTML.rendered(<<-HTML)
      <button#{attrs}>
        <span aria-hidden="true" class="#{track_classes}"><span class="#{thumb_classes}"></span></span>
        <span>#{label}</span>
      </button>
    HTML
  end

  private def render_field(
    label : String,
    control,
    id : String,
    hint : String?,
    error : String?,
    required : Bool,
    class_name : String?,
    attributes : Hash(String, String),
  ) : LF::LiveView::Rendered
    attrs = component_attributes(
      "space-y-0",
      class_name,
      attributes,
      {"data-opal-ui" => "field"}
    )
    marker = if required
               LF::LiveView::HTML.rendered(%(<span class="ml-1 text-red-600" aria-hidden="true">*</span>))
             else
               LF::LiveView::Rendered.opaque("")
             end
    hint_markup = optional_text(hint, "#{id}-hint", FIELD_HINT_CLASSES)
    error_markup = optional_text(error, "#{id}-error", FIELD_ERROR_CLASSES)
    LF::LiveView::HTML.rendered(<<-HTML)
      <div#{attrs}>
        <label for="#{id}" class="#{FIELD_LABEL_CLASSES}">#{label}#{marker}</label>
        #{control}#{hint_markup}#{error_markup}
      </div>
    HTML
  end

  private def choice_field(
    type : String,
    label : String,
    *,
    id : String,
    name : String,
    value : String,
    checked : Bool,
    hint : String?,
    error : String?,
    required : Bool,
    disabled : Bool,
    class_name : String?,
    input_class_name : String?,
    attributes : Hash(String, String),
  ) : LF::LiveView::Rendered
    validate_id!(id)
    validate_name!(name)
    fixed = {
      "id"           => id,
      "name"         => name,
      "type"         => type,
      "value"        => value,
      "data-opal-ui" => type,
    }
    add_accessibility_attributes(fixed, id, hint, error, required)
    booleans = [] of String
    booleans << "checked" if checked
    booleans << "required" if required
    booleans << "disabled" if disabled
    input_attrs = component_attributes(
      "#{CHOICE_BASE_CLASSES} #{type == "radio" ? "rounded-full" : "rounded"}",
      input_class_name,
      attributes,
      fixed,
      booleans
    )
    wrapper_attrs = component_attributes(
      "space-y-0",
      class_name,
      EMPTY_ATTRIBUTES,
      {"data-opal-ui" => "field"}
    )
    hint_markup = optional_text(hint, "#{id}-hint", "ml-7 #{FIELD_HINT_CLASSES}")
    error_markup = optional_text(error, "#{id}-error", "ml-7 #{FIELD_ERROR_CLASSES}")
    marker = if required
               LF::LiveView::HTML.rendered(%(<span class="ml-1 text-red-600" aria-hidden="true">*</span>))
             else
               LF::LiveView::Rendered.opaque("")
             end
    LF::LiveView::HTML.rendered(<<-HTML)
      <div#{wrapper_attrs}>
        <div class="flex items-start gap-3">
          <input#{input_attrs}>
          <label for="#{id}" class="text-sm font-medium text-slate-800 dark:text-slate-200">#{label}#{marker}</label>
        </div>
        #{hint_markup}#{error_markup}
      </div>
    HTML
  end

  private def add_accessibility_attributes(
    fixed : Hash(String, String),
    id : String,
    hint : String?,
    error : String?,
    required : Bool,
  ) : Nil
    described_by = [] of String
    described_by << "#{id}-hint" if hint
    described_by << "#{id}-error" if error
    fixed["aria-describedby"] = described_by.join(' ') unless described_by.empty?
    fixed["aria-invalid"] = "true" if error
    fixed["aria-required"] = "true" if required
  end

  private def select_options(
    options : Enumerable(SelectOption),
    selected : String?,
    prompt : String?,
  ) : LF::LiveView::HTML::Safe
    markup = String.build do |html|
      if prompt
        html << %(<option value="")
        html << " selected" if selected.nil? || selected.empty?
        html << '>' << LF::LiveView::HTML.escape(prompt) << "</option>"
      end
      options.each do |option|
        html << %(<option value=") << LF::LiveView::HTML.escape(option.value) << '"'
        html << " selected" if selected == option.value
        html << " disabled" if option.disabled?
        html << '>' << LF::LiveView::HTML.escape(option.label) << "</option>"
      end
    end
    LF::LiveView::HTML.raw(markup)
  end

  private def validate_name!(name : String) : Nil
    raise ArgumentError.new("UI form control name must not be blank") if name.blank?
  end

  private def control_state_classes(error : String?) : String
    if error
      "border-red-400 focus:border-red-500 focus:ring-red-500 dark:border-red-700"
    else
      "border-slate-300 focus:border-blue-500 focus:ring-blue-600 dark:border-slate-700"
    end
  end

  private def switch_track_classes(size : Size, checked : Bool) : String
    dimensions = case size
                 when .small?  then "h-5 w-9 p-0.5"
                 when .medium? then "h-6 w-11 p-0.5"
                 when .large?  then "h-7 w-12 p-0.5"
                 else               raise "Unsupported UI switch size"
                 end
    color = checked ? "bg-blue-600" : "bg-slate-300 dark:bg-slate-700"
    "inline-flex shrink-0 rounded-full transition-colors #{dimensions} #{color}"
  end

  private def switch_thumb_classes(size : Size, checked : Bool) : String
    dimensions = case size
                 when .small?  then "size-4"
                 when .medium? then "size-5"
                 when .large?  then "size-6"
                 else               raise "Unsupported UI switch size"
                 end
    translation = case size
                  when .small?  then checked ? "translate-x-4" : "translate-x-0"
                  when .medium? then checked ? "translate-x-5" : "translate-x-0"
                  when .large?  then checked ? "translate-x-5" : "translate-x-0"
                  else               raise "Unsupported UI switch size"
                  end
    "block rounded-full bg-white shadow-sm transition-transform #{dimensions} #{translation}"
  end
end
