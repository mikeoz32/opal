require "./spec_helper"
require "../src/opal/ui"

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
      attributes: {"id" => "save", "data-opal-click" => "save"}
    ).to_html

    html.should contain(%(data-opal-ui="button"))
    html.should contain(%(data-ui-variant="outline"))
    html.should contain(%(type="submit"))
    html.should contain(" disabled")
    html.should contain("border-red-300")
    html.should contain("w-full")
    html.should contain(%(data-opal-click="save"))
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
      LF::UI.button("Cancel", attributes: {"data-opal-click" => "close_publish"})
    )
    html = LF::UI.dialog(
      LF::LiveView::HTML.raw(header.to_html + body.to_html + footer.to_html),
      id: "publish-dialog",
      open: true,
      labelled_by: "publish-title",
      described_by: "publish-description",
      close_event: "close_publish",
      return_focus: "publish-button",
      attributes: {"data-opal-target" => "7"}
    ).to_html

    html.should contain(%(<dialog))
    html.should contain(%(id="publish-dialog"))
    html.should contain(%(role="dialog"))
    html.should contain(%(aria-modal="true"))
    html.should contain(%(aria-labelledby="publish-title"))
    html.should contain(%(aria-describedby="publish-description"))
    html.should contain(%(data-opal-hook="OpalDialog"))
    html.should contain(%(data-opal-dialog-open="true"))
    html.should contain(%(data-opal-dialog-close-escape="true"))
    html.should contain(%(data-opal-dialog-return-focus="publish-button"))
    html.should contain(%(data-opal-target="7"))
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

    html.should contain(%(data-opal-hook="OpalDropdown"))
    html.should contain(%(aria-haspopup="menu"))
    html.should contain(%(aria-expanded="false"))
    html.should contain(%(role="menu"))
    html.should contain(%(aria-labelledby="release-trigger"))
    html.should contain(%(data-opal-click="run_action"))
    html.should contain(%(data-opal-value-item="checks"))
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

    html.should contain(%(data-opal-hook="OpalTabs"))
    html.should contain(%(role="tablist"))
    html.should contain(%(aria-label="Release details"))
    html.should contain(%(aria-selected="true"))
    html.should contain(%(aria-controls="overview-panel"))
    html.should contain(%(data-opal-value-tab="activity"))
    html.should contain(%(<section class=))
    html.should contain(%(role="tabpanel"))
    html.should contain(%(id="activity-panel"))
    html.should contain(" hidden")
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
    html.should contain(%(data-opal-hook="OpalToast"))
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
      attributes: {"data-opal-change" => "validate"}
    ).to_html

    input.should contain(%(<label for="email"))
    input.should contain(%(aria-describedby="email-hint email-error"))
    input.should contain(%(aria-invalid="true"))
    input.should contain(%(aria-required="true"))
    input.should contain(" required")
    input.should contain(%(value="&lt;mike@example.com&gt;"))
    input.should contain("Already &lt;used&gt;")
    input.should contain(%(data-opal-change="validate"))

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
      attributes: {"data-opal-click" => "toggle_updates"}
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
