require "spec"
require "../src/ui_showcase"

describe UIShowcaseLive do
  it "renders every primitive family and handles live state" do
    view = UIShowcaseLive.new
    request = HTTP::Request.new("GET", "/")
    view.__opal_mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))
    view.__opal_handle_params(LF::LiveView::ParamsContext.new({} of String => String, request.resource))

    initial = view.__opal_render.to_html
    initial.should contain(%(data-opal-ui="button"))
    initial.should contain(%(data-opal-ui="alert"))
    initial.should contain(%(data-opal-ui="input"))
    initial.should contain(%(data-opal-ui="select"))
    initial.should contain(%(data-opal-ui="switch"))
    initial.should contain(%(data-opal-ui="table"))
    initial.should contain(%(data-opal-ui="dialog"))
    initial.should contain(%(data-opal-dialog-open="false"))
    initial.should contain(%(data-opal-ui="dropdown"))
    initial.should contain(%(data-opal-ui="tabs"))
    initial.should contain(%(data-opal-ui="toast-region"))
    initial.should_not contain(%(data-opal-ui="toast"))
    initial.should contain(%(data-opal-ui="accordion"))
    initial.should contain(%(phx-hook="OpalAccordion"))
    initial.should contain(%(id="checks-accordion-panel"))
    initial.should contain(%(aria-expanded="true"))
    initial.should contain(%(data-opal-ui="tooltip"))
    initial.should contain(%(phx-hook="OpalTooltip"))
    initial.should contain(%(data-opal-ui="pagination"))
    initial.should contain(%(data-phx-link="patch"))
    initial.should contain("Page 1 of 5")
    initial.should contain(%(data-opal-ui="data-table"))
    initial.should contain(%(id="release-data-table"))
    initial.should contain(%(aria-sort="descending"))
    initial.should contain(%(phx-click="sort_releases"))
    initial.should contain(%(phx-click="toggle_release"))
    initial.should contain(%(phx-click="toggle_release_page"))
    initial.should contain("Showing 1–3 of 8")

    view.__opal_handle_event(nil, "toggle_notifications", JSON.parse("{}"))
    view.__opal_handle_event(nil, "toggle_deployment", JSON.parse("{}"))
    view.__opal_handle_event(nil, "save_profile", JSON.parse(%({"name":"Mike","role":"admin"})))

    updated = view.__opal_render.to_html
    updated.should contain(%(id="notifications-switch"))
    updated.should contain(%(aria-checked="false"))
    updated.should contain("Ready to deploy")
    updated.should contain(%(id="saved-status"))

    view.__opal_handle_event(nil, "open_release_dialog", JSON.parse("{}"))
    opened = view.__opal_render.to_html
    opened.should contain(%(data-opal-dialog-open="true"))
    opened.should contain("Dialog update 0")

    view.__opal_handle_event(nil, "refresh_release_dialog", JSON.parse("{}"))
    refreshed = view.__opal_render.to_html
    refreshed.should contain("Dialog update 1")

    view.__opal_handle_event(nil, "close_release_dialog", JSON.parse(%({"reason":"escape"})))
    closed = view.__opal_render.to_html
    closed.should contain(%(data-opal-dialog-open="false"))
    closed.should contain("Closed by escape")

    view.__opal_handle_event(nil, "run_menu_action", JSON.parse(%({"item":"checks"})))
    menu_updated = view.__opal_render.to_html
    menu_updated.should contain("Selected checks")

    view.__opal_handle_event(nil, "select_component_tab", JSON.parse(%({"tab":"activity"})))
    tabs_updated = view.__opal_render.to_html
    tabs_updated.should contain(%(id="activity-tab"))
    tabs_updated.should contain(%(aria-selected="true"))
    tabs_updated.should contain("Recent builds and deployment events.")

    view.__opal_handle_event(nil, "show_release_toast", JSON.parse("{}"))
    toast_visible = view.__opal_render.to_html
    toast_visible.should contain(%(data-opal-ui="toast"))
    toast_visible.should contain("Release ready")

    view.__opal_handle_event(nil, "dismiss_release_toast", JSON.parse(%({"reason":"button"})))
    toast_dismissed = view.__opal_render.to_html
    toast_dismissed.should_not contain(%(data-opal-ui="toast"))
    toast_dismissed.should contain("Toast dismissed by button")

    view.__opal_handle_event(nil, "toggle_accordion", JSON.parse(%({"item":"checks"})))
    accordion_collapsed = view.__opal_render.to_html
    accordion_collapsed.should contain(%(id="checks-accordion-trigger"))
    accordion_collapsed.should contain(%(aria-expanded="false"))
    accordion_collapsed.should contain(%(id="checks-accordion-panel"))

    view.__opal_handle_event(nil, "toggle_accordion", JSON.parse(%({"item":"artifacts"})))
    accordion_expanded = view.__opal_render.to_html
    accordion_expanded.should contain(%(id="artifacts-accordion-trigger"))
    accordion_expanded.should contain(%(aria-expanded="true"))

    view.__opal_handle_event(nil, "toggle_release", JSON.parse(%({"row":"release-160-dev"})))
    selected = view.__opal_render.to_html
    selected.should contain(%(id="release-data-table-row-release-160-dev"))
    selected.should contain(%(data-selected="true"))
    selected.should contain("1 selected")
    selected.should contain(%(id="clear-release-selection"))

    view.__opal_handle_event(nil, "clear_release_selection", JSON.parse("{}"))
    cleared = view.__opal_render.to_html
    cleared.should contain("0 selected")
    cleared.should_not contain(%(id="clear-release-selection"))

    view.__opal_handle_event(nil, "set_data_table_state", JSON.parse(%({"state":"loading"})))
    loading = view.__opal_render.to_html
    loading.should contain(%(data-state="loading"))
    loading.should contain(%(aria-busy="true"))

    view.__opal_handle_event(nil, "set_data_table_state", JSON.parse(%({"state":"empty"})))
    empty = view.__opal_render.to_html
    empty.should contain(%(data-state="empty"))
    empty.should contain("No releases match the current filters.")

    view.__opal_handle_event(nil, "set_data_table_state", JSON.parse(%({"state":"error"})))
    failed = view.__opal_render.to_html
    failed.should contain(%(data-state="error"))
    failed.should contain(%(role="alert"))

    view.__opal_handle_event(nil, "set_data_table_state", JSON.parse(%({"state":"ready"})))

    view.__opal_handle_params(LF::LiveView::ParamsContext.new({} of String => String, "/?page=3"))
    paged = view.__opal_render.to_html
    paged.should contain("Page 3 of 5")
    paged.should contain(%(href="/?page=3"))
    paged.should contain(%(aria-current="page"))

    view.__opal_handle_params(
      LF::LiveView::ParamsContext.new(
        {} of String => String,
        "/?page=3&table_page=2&table_sort=checks&table_dir=asc"
      )
    )
    data_paged = view.__opal_render.to_html
    data_paged.should contain("Showing 4–6 of 8")
    data_paged.should contain(%(data-column="checks" aria-sort="ascending"))
    data_paged.should contain(%(aria-label="Release table page 2"))
  ensure
    view.try(&.__opal_disconnect)
  end

  it "renders accessible validation errors" do
    view = UIShowcaseLive.new
    request = HTTP::Request.new("GET", "/")
    view.__opal_mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))
    view.__opal_handle_event(nil, "validate_profile", JSON.parse(%({"name":"","role":""})))

    rendered = view.__opal_render.to_html
    rendered.should contain("Name is required")
    rendered.should contain("Choose a role")
    rendered.should contain(%(aria-describedby="profile-name-hint profile-name-error"))
    rendered.should contain(%(aria-invalid="true"))
  ensure
    view.try(&.__opal_disconnect)
  end
end
