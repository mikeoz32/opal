module LF::UI
  PAGINATION_LINK = "inline-flex min-h-9 min-w-9 items-center justify-center rounded-lg border px-3 text-sm font-semibold no-underline outline-none transition-colors focus-visible:ring-2 focus-visible:ring-blue-600 disabled:pointer-events-none disabled:opacity-50"

  def pagination(
    content,
    *,
    label : String = "Pagination",
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    if label.blank?
      raise ArgumentError.new("UI pagination label must not be blank")
    end
    attrs = component_attributes(
      "w-full",
      class_name,
      attributes,
      {
        "aria-label"   => label,
        "data-opal-ui" => "pagination",
      }
    )
    LF::LiveView::HTML.rendered(%(<nav#{attrs}><ul class="flex flex-wrap items-center gap-1">#{content}</ul></nav>))
  end

  def pagination_link(
    content,
    href : String,
    *,
    label : String? = nil,
    current : Bool = false,
    disabled : Bool = false,
    live_patch : Bool = false,
    replace : Bool = false,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    validate_href!(href)
    if label && label.blank?
      raise ArgumentError.new("UI pagination link label must not be blank")
    end
    if replace && !live_patch
      raise ArgumentError.new("UI pagination replace requires live_patch")
    end
    validate_pagination_patch_href!(href) if live_patch

    fixed = {
      "role"         => "link",
      "data-opal-ui" => "pagination-link",
    }
    label.try { |value| fixed["aria-label"] = value }
    fixed["aria-current"] = "page" if current
    if disabled
      fixed["aria-disabled"] = "true"
      fixed["tabindex"] = "-1"
    else
      fixed["href"] = href
      if live_patch
        fixed["data-phx-link"] = "patch"
        fixed["data-phx-link-state"] = replace ? "replace" : "push"
      end
    end

    state_classes = if current
                      "border-blue-600 bg-blue-600 text-white dark:border-blue-500 dark:bg-blue-500"
                    else
                      "border-slate-300 bg-white text-slate-700 hover:bg-slate-100 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-200 dark:hover:bg-slate-800"
                    end
    attrs = component_attributes(
      "#{PAGINATION_LINK} #{state_classes} #{disabled ? "pointer-events-none opacity-50" : "cursor-pointer"}",
      class_name,
      attributes,
      fixed
    )
    LF::LiveView::HTML.rendered(%(<li data-opal-ui="pagination-item"><a#{attrs}>#{content}</a></li>))
  end

  def pagination_ellipsis(
    label : String = "More pages",
    *,
    class_name : String? = nil,
    attributes : Hash(String, String) = EMPTY_ATTRIBUTES,
  ) : LF::LiveView::Rendered
    if label.blank?
      raise ArgumentError.new("UI pagination ellipsis label must not be blank")
    end
    attrs = component_attributes(
      "inline-flex min-h-9 min-w-9 items-center justify-center px-2 text-sm text-slate-500 dark:text-slate-400",
      class_name,
      attributes,
      {
        "data-opal-ui" => "pagination-ellipsis",
      }
    )
    LF::LiveView::HTML.rendered(
      %(<li data-opal-ui="pagination-item"><span#{attrs}><span aria-hidden="true">…</span><span class="sr-only">#{label}</span></span></li>)
    )
  end

  private def validate_pagination_patch_href!(href : String) : Nil
    unless href.starts_with?('/') && !href.starts_with?("//") && !href.includes?('#')
      raise ArgumentError.new("UI pagination live patch href must be a local absolute resource")
    end
  end
end
