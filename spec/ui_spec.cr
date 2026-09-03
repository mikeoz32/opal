require "./spec_helper"
require "../src/opal/ui"

record UIDataTableSpecRow, id : String, name : String, score : Int32

describe LF::UI do
  it "renders typed buttons and safely extends their attributes" do
    html = LF::UI.button(
      "Save <draft>",
      variant: LF::UI::ButtonVariant::Outline,
      tone: LF::UI::Tone::Danger,
      size: LF::UI::Size::Large,
      type: "submit",
      disabled: true,
      class_name: "w-full",
      attributes: {"id" => "save", "phx-click" => "save"}
    ).to_html

    html.should contain(%(data-opal-ui="button"))
    html.should contain(%(data-ui-variant="outline"))
    html.should contain(%(type="submit"))
    html.should contain(" disabled")
    html.should contain("border-red-300")
    html.should contain("w-full")
    html.should contain(%(phx-click="save"))
    html.should contain("Save &lt;draft&gt;")
  end

  it "renders safe enabled and disabled link buttons" do
    enabled = LF::UI.link_button(
      "Docs",
      "https://example.com/?a=1&b=2",
      target: "_blank"
    ).to_html
    enabled.should contain(%(href="https://example.com/?a=1&amp;b=2"))
    enabled.should contain(%(rel="noopener noreferrer"))

    disabled = LF::UI.link_button("Unavailable", "/later", disabled: true).to_html
    disabled.should_not contain(" href=")
    disabled.should contain(%(aria-disabled="true"))
    disabled.should contain(%(tabindex="-1"))
  end

  it "rejects script URLs, event handlers, and typed attribute overrides" do
    expect_raises(ArgumentError, "Unsafe UI link scheme 'javascript'") do
      LF::UI.link_button("Bad", "javascript:alert(1)")
    end
    expect_raises(ArgumentError, "Unsafe UI attribute 'onclick'") do
      LF::UI.button("Bad", attributes: {"onclick" => "alert(1)"})
    end
    expect_raises(ArgumentError, "must use its typed component argument") do
      LF::UI.button("Bad", attributes: {"type" => "submit"})
    end
    expect_raises(ArgumentError, "Legacy UI LiveView binding 'data-opal-click'; use 'phx-click'") do
      LF::UI.button("Old binding", attributes: {"data-opal-click" => "save"})
    end
    expect_raises(ArgumentError, "Legacy UI LiveView binding 'data-opal-value-id'; use 'phx-value-id'") do
      LF::UI.button("Old value", attributes: {"data-opal-value-id" => "42"})
    end
    expect_raises(ArgumentError, "Legacy UI LiveView binding 'data-opal-window-keydown'; use 'phx-window-keydown'") do
      LF::UI.button("Old key binding", attributes: {"data-opal-window-keydown" => "close"})
    end
  end

  it "renders feedback and composable cards without escaping trusted children" do
    badge = LF::UI.badge("Stable", tone: LF::UI::Tone::Success)
    header = LF::UI.card_header(
      LF::UI.card_title("Release <status>", level: 3)
    )
    body = LF::UI.card_body(LF::UI.alert(badge, title: "Ready", tone: LF::UI::Tone::Success))
    html = LF::UI.card(
      LF::LiveView::HTML.raw(header.to_html + body.to_html)
    ).to_html

    html.should contain(%(data-opal-ui="card"))
    html.should contain("<h3")
    html.should contain("Release &lt;status&gt;")
    html.should contain(%(data-opal-ui="alert"))
    html.should contain(%(data-opal-ui="badge"))
    html.should contain(">Stable</span>")
  end

  it "renders an accessible server-controlled dialog" do
    header = LF::UI.dialog_header(
      LF::LiveView::HTML.raw(
        LF::UI.dialog_title("Publish release", id: "publish-title").to_html +
        LF::UI.dialog_description("Confirm the release.", id: "publish-description").to_html
      )
    )
    body = LF::UI.dialog_body("Version <1.0>")
    footer = LF::UI.dialog_footer(
      LF::UI.button("Cancel", attributes: {"phx-click" => "close_publish"})
    )
    html = LF::UI.dialog(
      LF::LiveView::HTML.raw(header.to_html + body.to_html + footer.to_html),
      id: "publish-dialog",
      open: true,
      labelled_by: "publish-title",
      described_by: "publish-description",
      close_event: "close_publish",
      return_focus: "publish-button",
      attributes: {"phx-target" => "7"}
    ).to_html

    html.should contain(%(<dialog))
    html.should contain(%(id="publish-dialog"))
    html.should contain(%(role="dialog"))
    html.should contain(%(aria-modal="true"))
    html.should contain(%(aria-labelledby="publish-title"))
    html.should contain(%(aria-describedby="publish-description"))
    html.should contain(%(phx-hook="OpalDialog"))
    html.should contain(%(data-opal-dialog-open="true"))
    html.should contain(%(data-opal-dialog-close-escape="true"))
    html.should contain(%(data-opal-dialog-return-focus="publish-button"))
    html.should contain(%(phx-target="7"))
    html.should contain(%(data-opal-ui="dialog-panel"))
    html.should contain("Version &lt;1.0&gt;")
  end

  it "rejects invalid dialog identities and close events" do
    expect_raises(ArgumentError, "UI element id must not be blank") do
      LF::UI.dialog("Content", id: "", open: false, labelled_by: "title", close_event: "close")
    end
    expect_raises(ArgumentError, "UI element id must not contain whitespace") do
      LF::UI.dialog("Content", id: "dialog", open: false, labelled_by: "bad title", close_event: "close")
    end
    expect_raises(ArgumentError, "UI dialog close event must not be blank") do
      LF::UI.dialog("Content", id: "dialog", open: false, labelled_by: "title", close_event: "")
    end
  end

  it "renders an accessible dropdown menu with typed actions and links" do
    trigger = LF::UI.dropdown_trigger(
      "Release actions",
      id: "release-trigger",
      controls: "release-menu"
    )
    menu = LF::UI.dropdown_menu(
      LF::LiveView::HTML.raw(
        LF::UI.dropdown_item("Run checks", event: "run_action", value: "checks").to_html +
        LF::UI.dropdown_item("Deploy", disabled: true).to_html +
        LF::UI.dropdown_link("Documentation", "https://example.com/docs?a=1&b=2").to_html
      ),
      id: "release-menu",
      labelled_by: "release-trigger",
      align: LF::UI::MenuAlign::End
    )
    html = LF::UI.dropdown(
      LF::LiveView::HTML.raw(trigger.to_html + menu.to_html),
      id: "release-dropdown"
    ).to_html

    html.should contain(%(phx-hook="OpalDropdown"))
    html.should contain(%(aria-haspopup="menu"))
    html.should contain(%(aria-expanded="false"))
    html.should contain(%(role="menu"))
    html.should contain(%(aria-labelledby="release-trigger"))
    html.should contain(%(phx-click="run_action"))
    html.should contain(%(phx-value-item="checks"))
    html.should contain(%(href="https://example.com/docs?a=1&amp;b=2"))
    html.should contain(" hidden")
    html.should contain(" disabled")
  end

  it "rejects incomplete dropdown actions" do
    expect_raises(ArgumentError, "UI dropdown item value requires an event") do
      LF::UI.dropdown_item("Run", value: "checks")
    end
    expect_raises(ArgumentError, "UI dropdown item event must not be blank") do
      LF::UI.dropdown_item("Run", event: "")
    end
  end

  it "renders server-controlled accessible tabs and panels" do
    list = LF::UI.tab_list(
      LF::LiveView::HTML.raw(
        LF::UI.tab(
          "Overview",
          id: "overview-tab",
          panel_id: "overview-panel",
          selected: true,
          select_event: "select_tab",
          value: "overview"
        ).to_html +
        LF::UI.tab(
          "Activity",
          id: "activity-tab",
          panel_id: "activity-panel",
          selected: false,
          select_event: "select_tab",
          value: "activity"
        ).to_html
      ),
      label: "Release details"
    )
    panels = LF::UI.tab_panel(
      "Current release",
      id: "overview-panel",
      labelled_by: "overview-tab",
      selected: true
    ).to_html + LF::UI.tab_panel(
      "Recent activity",
      id: "activity-panel",
      labelled_by: "activity-tab",
      selected: false
    ).to_html
    html = LF::UI.tabs(
      LF::LiveView::HTML.raw(list.to_html + panels),
      id: "release-tabs"
    ).to_html

    html.should contain(%(phx-hook="OpalTabs"))
    html.should contain(%(role="tablist"))
    html.should contain(%(aria-label="Release details"))
    html.should contain(%(aria-selected="true"))
    html.should contain(%(aria-controls="overview-panel"))
    html.should contain(%(phx-value-tab="activity"))
    html.should contain(%(<section class=))
    html.should contain(%(role="tabpanel"))
    html.should contain(%(id="activity-panel"))
    html.should contain(" hidden")
  end

  it "renders a server-controlled accessible accordion" do
    trigger = LF::UI.accordion_trigger(
      "Release checks",
      id: "checks-trigger",
      panel_id: "checks-panel",
      expanded: true,
      toggle_event: "toggle_section",
      value: "checks"
    )
    panel = LF::UI.accordion_panel(
      "All required checks passed.",
      id: "checks-panel",
      labelled_by: "checks-trigger",
      expanded: true
    )
    collapsed_trigger = LF::UI.accordion_trigger(
      "Rollback plan",
      id: "rollback-trigger",
      panel_id: "rollback-panel",
      expanded: false,
      toggle_event: "toggle_section",
      value: "rollback"
    )
    collapsed_panel = LF::UI.accordion_panel(
      "Rollback steps.",
      id: "rollback-panel",
      labelled_by: "rollback-trigger",
      expanded: false
    )
    html = LF::UI.accordion(
      LF::LiveView::HTML.raw(
        LF::UI.accordion_item(
          LF::LiveView::HTML.raw(trigger.to_html + panel.to_html)
        ).to_html + LF::UI.accordion_item(
          LF::LiveView::HTML.raw(collapsed_trigger.to_html + collapsed_panel.to_html)
        ).to_html
      ),
      id: "release-accordion",
      label: "Release checklist"
    ).to_html

    html.should contain(%(phx-hook="OpalAccordion"))
    html.should contain(%(aria-label="Release checklist"))
    html.should contain(%(aria-expanded="true"))
    html.should contain(%(aria-controls="checks-panel"))
    html.should contain(%(phx-click="toggle_section"))
    html.should contain(%(phx-value-item="checks"))
    html.should contain(%(role="region"))
    html.should contain(%(aria-labelledby="checks-trigger"))
    html.should contain(%(id="rollback-panel"))
    html.should contain(" hidden")
  end

  it "rejects invalid accordion contracts" do
    expect_raises(ArgumentError, "UI accordion label must not be blank") do
      LF::UI.accordion("Content", id: "accordion", label: "")
    end
    expect_raises(ArgumentError, "UI accordion toggle event must not be blank") do
      LF::UI.accordion_trigger("Title", id: "trigger", panel_id: "panel", expanded: false, toggle_event: "")
    end
    expect_raises(ArgumentError, "UI accordion heading level must be between 1 and 6") do
      LF::UI.accordion_trigger("Title", id: "trigger", panel_id: "panel", expanded: false, toggle_event: "toggle", heading_level: 7)
    end
  end

  it "renders an accessible local tooltip" do
    html = LF::UI.tooltip(
      "?",
      "Only validated releases can be published.",
      id: "release-help",
      trigger_label: "About release readiness",
      position: LF::UI::TooltipPosition::Right,
      delay_ms: 150,
      trigger_attributes: {"phx-click" => "explain_release"}
    ).to_html

    html.should contain(%(id="release-help"))
    html.should contain(%(phx-hook="OpalTooltip"))
    html.should contain(%(data-opal-tooltip-delay="150"))
    html.should contain(%(id="release-help-trigger"))
    html.should contain(%(aria-label="About release readiness"))
    html.should contain(%(aria-describedby="release-help-content"))
    html.should contain(%(phx-click="explain_release"))
    html.should contain(%(id="release-help-content"))
    html.should contain(%(role="tooltip"))
    html.should contain("left-full")
    html.should contain(" hidden")
  end

  it "rejects invalid tooltip contracts" do
    expect_raises(ArgumentError, "UI tooltip trigger label must not be blank") do
      LF::UI.tooltip("?", "Help", id: "help", trigger_label: "")
    end
    expect_raises(ArgumentError, "UI tooltip delay must not be negative") do
      LF::UI.tooltip("?", "Help", id: "help", delay_ms: -1)
    end
  end

  it "renders accessible pagination with Phoenix live patches" do
    links = LF::UI.pagination_link(
      "Previous",
      "/?page=1",
      label: "Previous page",
      disabled: true,
      live_patch: true
    ).to_html + LF::UI.pagination_link(
      "2",
      "/?page=2",
      label: "Page 2",
      current: true,
      live_patch: true,
      replace: true
    ).to_html + LF::UI.pagination_ellipsis.to_html
    html = LF::UI.pagination(
      LF::LiveView::HTML.raw(links),
      label: "Release pages"
    ).to_html

    html.should contain(%(<nav))
    html.should contain(%(aria-label="Release pages"))
    html.should contain(%(aria-disabled="true"))
    html.should contain(%(tabindex="-1"))
    html.should contain(%(href="/?page=2"))
    html.should contain(%(aria-current="page"))
    html.should contain(%(data-phx-link="patch"))
    html.should contain(%(data-phx-link-state="replace"))
    html.should contain(%(aria-hidden="true">…</span>))
    html.should contain(%(<span class="sr-only">More pages</span>))
  end

  it "rejects invalid pagination navigation" do
    expect_raises(ArgumentError, "UI pagination label must not be blank") do
      LF::UI.pagination("Pages", label: "")
    end
    expect_raises(ArgumentError, "UI pagination replace requires live_patch") do
      LF::UI.pagination_link("2", "/?page=2", replace: true)
    end
    expect_raises(ArgumentError, "UI pagination live patch href must be a local absolute resource") do
      LF::UI.pagination_link("External", "https://example.com", live_patch: true)
    end
  end

  it "renders a typed server-driven data table" do
    rows = [
      UIDataTableSpecRow.new("alpha", "Alpha <one>", 12),
      UIDataTableSpecRow.new("beta", "Beta", 8),
    ]
    columns = [
      LF::UI::DataTableColumn(UIDataTableSpecRow).new(
        "name",
        "Name",
        sortable: true,
        row_header: true
      ) { |row| LF::LiveView::HTML.rendered(%(#{row.name})) },
      LF::UI::DataTableColumn(UIDataTableSpecRow).new(
        "score",
        "Score",
        alignment: LF::UI::DataTableColumnAlignment::End,
        sortable: true
      ) { |row| LF::LiveView::HTML.rendered(%(#{row.score})) },
    ]
    pages = LF::UI.pagination(
      LF::UI.pagination_link("2", "/?page=2", current: true, live_patch: true),
      label: "Result pages"
    )
    html = LF::UI.data_table(
      rows,
      columns,
      id: "results",
      caption: "Search <results>",
      row_key: ->(row : UIDataTableSpecRow) { row.id },
      sort_key: "score",
      sort_direction: LF::UI::DataTableSortDirection::Descending,
      sort_event: "sort_results",
      selected_keys: Set{"alpha"},
      select_event: "toggle_result",
      select_all_event: "toggle_results",
      selection_label: ->(row : UIDataTableSpecRow) { "result #{row.name}" },
      bulk_actions: LF::UI.button("Archive", attributes: {"phx-click" => "archive_results"}),
      page_info: LF::UI::DataTablePageInfo.new(2, 2, 5),
      pagination: pages
    ).to_html

    html.should contain(%(id="results"))
    html.should contain(%(data-opal-ui="data-table"))
    html.should contain("Search &lt;results&gt;")
    html.should contain(%(aria-sort="descending"))
    html.should contain(%(phx-click="sort_results"))
    html.should contain(%(phx-value-sort="score"))
    html.should contain(%(phx-value-direction="asc"))
    html.should contain(%(aria-checked="mixed"))
    html.should contain(%(phx-click="toggle_result"))
    html.should contain(%(phx-value-row="alpha"))
    html.should contain(%(id="results-row-alpha"))
    html.should contain(%(data-selected="true"))
    html.should contain(%(<th))
    html.should contain(%(scope="row"))
    html.should contain("Alpha &lt;one&gt;")
    html.should contain("1 selected")
    html.should contain(%(phx-click="archive_results"))
    html.should contain("Showing 3–4 of 5")
    html.should contain(%(data-phx-link="patch"))
  end

  it "renders data table loading, empty, and error states" do
    columns = [
      LF::UI::DataTableColumn(UIDataTableSpecRow).new("name", "Name") do |row|
        LF::LiveView::HTML.rendered(%(#{row.name}))
      end,
    ]
    row_key = ->(row : UIDataTableSpecRow) { row.id }

    loading = LF::UI.data_table(
      [] of UIDataTableSpecRow,
      columns,
      id: "loading-results",
      caption: "Loading results",
      row_key: row_key,
      loading: true
    ).to_html
    loading.should contain(%(aria-busy="true"))
    loading.should contain(%(data-state="loading"))
    loading.should contain("Loading rows…")

    empty = LF::UI.data_table(
      [] of UIDataTableSpecRow,
      columns,
      id: "empty-results",
      caption: "Empty results",
      row_key: row_key,
      empty_message: "Nothing matched."
    ).to_html
    empty.should contain(%(data-state="empty"))
    empty.should contain("Nothing matched.")

    failed = LF::UI.data_table(
      [] of UIDataTableSpecRow,
      columns,
      id: "failed-results",
      caption: "Failed results",
      row_key: row_key,
      error_message: "Could not load <results>."
    ).to_html
    failed.should contain(%(data-state="error"))
    failed.should contain(%(role="alert"))
    failed.should contain("Could not load &lt;results&gt;.")
  end

  it "rejects invalid data table contracts" do
    column = LF::UI::DataTableColumn(UIDataTableSpecRow).new("name", "Name", sortable: true) do |row|
      LF::LiveView::HTML.rendered(%(#{row.name}))
    end
    rows = [
      UIDataTableSpecRow.new("duplicate", "First", 1),
      UIDataTableSpecRow.new("duplicate", "Second", 2),
    ]
    row_key = ->(row : UIDataTableSpecRow) { row.id }

    expect_raises(ArgumentError, "UI data table sortable columns require a sort event") do
      LF::UI.data_table(rows.first(1), [column], id: "results", caption: "Results", row_key: row_key)
    end
    expect_raises(ArgumentError, "UI data table row and select-all events must be provided together") do
      LF::UI.data_table(
        rows.first(1),
        [column],
        id: "results",
        caption: "Results",
        row_key: row_key,
        sort_event: "sort",
        select_event: "select"
      )
    end
    expect_raises(ArgumentError, "UI data table row keys must be unique") do
      LF::UI.data_table(rows, [column], id: "results", caption: "Results", row_key: row_key, sort_event: "sort")
    end
    expect_raises(ArgumentError, "UI data table page size must be positive") do
      LF::UI::DataTablePageInfo.new(1, 0, 10)
    end
  end

  it "renders a live toast region with server-owned dismissal" do
    toast = LF::UI.toast(
      "Version <1.0> is ready.",
      id: "release-toast",
      title: "Release <ready>",
      tone: LF::UI::Tone::Success,
      dismiss_event: "dismiss_toast",
      auto_dismiss_ms: 5_000,
      dismiss_label: "Close release notification",
      return_focus: "show-toast"
    )
    html = LF::UI.toast_region(toast, id: "notifications").to_html

    html.should contain(%(role="region"))
    html.should contain(%(aria-live="polite"))
    html.should contain(%(phx-hook="OpalToast"))
    html.should contain(%(data-opal-toast-dismiss-event="dismiss_toast"))
    html.should contain(%(data-opal-toast-duration="5000"))
    html.should contain(%(data-opal-toast-return-focus="show-toast"))
    html.should contain(%(aria-label="Close release notification"))
    html.should contain("Release &lt;ready&gt;")
    html.should contain("Version &lt;1.0&gt; is ready.")
  end

  it "rejects invalid toast dismissal contracts" do
    expect_raises(ArgumentError, "UI toast auto dismiss requires a dismiss event") do
      LF::UI.toast("Ready", id: "toast", auto_dismiss_ms: 1_000)
    end
    expect_raises(ArgumentError, "UI toast auto dismiss duration must be greater than zero") do
      LF::UI.toast("Ready", id: "toast", dismiss_event: "dismiss", auto_dismiss_ms: 0)
    end
    expect_raises(ArgumentError, "UI toast return focus requires a dismiss event") do
      LF::UI.toast("Ready", id: "toast", return_focus: "show-toast")
    end
  end

  it "renders accessible text controls, errors, and escaped values" do
    input = LF::UI.input(
      "Email",
      id: "email",
      name: "email",
      value: %(<mike@example.com>),
      type: "email",
      autocomplete: "email",
      hint: "Work address",
      error: "Already <used>",
      required: true,
      attributes: {"phx-change" => "validate"}
    ).to_html

    input.should contain(%(<label for="email"))
    input.should contain(%(aria-describedby="email-hint email-error"))
    input.should contain(%(aria-invalid="true"))
    input.should contain(%(aria-required="true"))
    input.should contain(" required")
    input.should contain(%(value="&lt;mike@example.com&gt;"))
    input.should contain("Already &lt;used&gt;")
    input.should contain(%(phx-change="validate"))

    textarea = LF::UI.textarea(
      "Notes",
      id: "notes",
      name: "notes",
      value: "one </textarea> two",
      rows: 6
    ).to_html
    textarea.should contain(%(rows="6"))
    textarea.should contain("one &lt;/textarea&gt; two")
  end

  it "renders select, checkbox, radio, and switch states" do
    options = [
      LF::UI::SelectOption.new("admin", "Administrator"),
      LF::UI::SelectOption.new("reader", "Read <only>", disabled: true),
    ]
    select_html = LF::UI.select(
      "Role",
      options,
      id: "role",
      name: "role",
      selected: "admin",
      prompt: "Choose one"
    ).to_html
    select_html.should contain(%(<option value="admin" selected>Administrator</option>))
    select_html.should contain(%(<option value="reader" disabled>Read &lt;only&gt;</option>))

    checkbox = LF::UI.checkbox(
      "Product updates",
      id: "updates",
      name: "updates",
      checked: true
    ).to_html
    checkbox.should contain(%(type="checkbox"))
    checkbox.should contain(" checked")

    radio = LF::UI.radio(
      "Business",
      id: "business",
      name: "plan",
      value: "business",
      checked: true
    ).to_html
    radio.should contain(%(type="radio"))
    radio.should contain(%(value="business"))

    switch = LF::UI.switch(
      "Automatic updates",
      id: "automatic-updates",
      checked: true,
      attributes: {"phx-click" => "toggle_updates"}
    ).to_html
    switch.should contain(%(role="switch"))
    switch.should contain(%(aria-checked="true"))
    switch.should contain("translate-x-5")
  end

  it "renders accessible composable tables" do
    header = LF::UI.table_head(
      LF::UI.table_row(
        LF::LiveView::HTML.raw(
          LF::UI.table_header("Name").to_html +
          LF::UI.table_header("Status").to_html
        )
      )
    )
    body = LF::UI.table_body(
      LF::UI.table_row(
        LF::LiveView::HTML.raw(
          LF::UI.table_cell("Opal").to_html +
          LF::UI.table_cell(LF::UI.badge("Ready", tone: LF::UI::Tone::Success)).to_html
        )
      )
    )
    html = LF::UI.table(
      LF::LiveView::HTML.raw(header.to_html + body.to_html),
      caption: "Release status"
    ).to_html

    html.should contain(%(<caption class="sr-only">Release status</caption>))
    html.should contain(%(scope="col"))
    html.should contain(%(data-opal-ui="table-body"))
    html.should contain(">Opal</td>")
  end

  it "ships a compiled Tailwind theme with inline and linked helpers" do
    LF::UI.stylesheet.bytesize.should be > 10_000
    LF::UI.stylesheet.should contain("tailwindcss v4.3.3")
    LF::UI.stylesheet.should contain(".bg-blue-600")

    inline = LF::UI.stylesheet_tag(%(nonce"value)).value
    inline.should start_with(%(<style data-opal-ui-theme nonce="nonce&quot;value">))
    inline.should end_with("</style>")

    link = LF::UI.stylesheet_link("/assets/ui.css?v=1&theme=opal").value
    link.should eq(%(<link rel="stylesheet" href="/assets/ui.css?v=1&amp;theme=opal" data-opal-ui-theme>))
  end

  it "ships optional interaction hooks with inline and linked helpers" do
    LF::UI.hooks.should contain("OpalDialog")
    LF::UI.hooks.should contain("OpalDropdown")
    LF::UI.hooks.should contain("OpalTabs")
    LF::UI.hooks.should contain("OpalToast")
    LF::UI.hooks.should contain("OpalAccordion")
    LF::UI.hooks.should contain("OpalTooltip")
    LF::UI.hooks.should contain("showModal")

    inline = LF::UI.hook_script_tag(%(nonce"value)).value
    inline.should start_with(%(<script data-opal-ui-hooks nonce="nonce&quot;value">))
    inline.should contain("OpalDialog")
    inline.should end_with("</script>")

    link = LF::UI.hook_script_link("/assets/ui.js?v=1&theme=opal").value
    link.should eq(%(<script src="/assets/ui.js?v=1&amp;theme=opal" data-opal-ui-hooks></script>))
  end

  it "mounts the compiled theme and hooks as cacheable HTTP assets" do
    router = LF::HTTP::Router.new
    LF::UI.mount_assets(router)
    css_io = IO::Memory.new
    css_request = HTTP::Request.new("GET", LF::UI::STYLESHEET_PATH)
    css_response = HTTP::Server::Response.new(css_io)

    router.call(HTTP::Server::Context.new(css_request, css_response))
    css_response.close

    css_response.status.should eq(HTTP::Status::OK)
    css_response.content_type.should eq("text/css; charset=utf-8")
    css_response.headers["Cache-Control"].should eq("public, max-age=3600")
    css_io.to_s.split("\r\n\r\n", 2)[1].should eq(LF::UI.stylesheet)

    hooks_io = IO::Memory.new
    hooks_request = HTTP::Request.new("GET", LF::UI::HOOKS_PATH)
    hooks_response = HTTP::Server::Response.new(hooks_io)

    router.call(HTTP::Server::Context.new(hooks_request, hooks_response))
    hooks_response.close

    hooks_response.status.should eq(HTTP::Status::OK)
    hooks_response.content_type.should eq("text/javascript; charset=utf-8")
    hooks_response.headers["Cache-Control"].should eq("public, max-age=3600")
    hooks_io.to_s.split("\r\n\r\n", 2)[1].should eq(LF::UI.hooks)
  end
end
