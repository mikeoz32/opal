require "opal"
require "opal/ui"
require "opal/autoconfig/http"

@[LF::LiveView::Page("/")]
class UIShowcaseLive < LF::LiveView::View
  @name = ""
  @role = ""
  @validation_count = 0
  @notifications = true
  @deployment_ready = false
  @saved = false
  @release_dialog_open = false
  @dialog_revision = 0
  @last_dialog_close_reason = ""
  @selected_tab = "overview"
  @last_menu_action = ""
  @toast_visible = false
  @toast_sequence = 0
  @last_toast_dismiss_reason = ""
  @expanded_sections = Set{"checks"}
  @current_page = 1

  def handle_params(context : LF::LiveView::ParamsContext) : Nil
    page = context.query_params["page"]?.try(&.to_i?) || 1
    @current_page = page.clamp(1, 5)
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "validate_profile"
      update_profile(value)
      @validation_count += 1
      @saved = false
    when "save_profile"
      update_profile(value)
      @validation_count += 1
      @saved = !@name.blank? && !@role.blank?
    when "toggle_notifications"
      @notifications = !@notifications
    when "toggle_deployment"
      @deployment_ready = !@deployment_ready
    when "open_release_dialog"
      @release_dialog_open = true
      @last_dialog_close_reason = ""
    when "refresh_release_dialog"
      @dialog_revision += 1
    when "close_release_dialog"
      @release_dialog_open = false
      @last_dialog_close_reason = string_value(value, "reason")
    when "run_menu_action"
      @last_menu_action = string_value(value, "item")
    when "select_component_tab"
      selected = string_value(value, "tab")
      @selected_tab = selected if {"overview", "activity", "settings"}.includes?(selected)
    when "show_release_toast"
      @toast_sequence += 1
      @toast_visible = true
      @last_toast_dismiss_reason = ""
    when "dismiss_release_toast"
      @toast_visible = false
      @last_toast_dismiss_reason = string_value(value, "reason")
    when "toggle_accordion"
      section = string_value(value, "item")
      if {"checks", "artifacts", "rollback"}.includes?(section)
        if @expanded_sections.includes?(section)
          @expanded_sections.delete(section)
        else
          @expanded_sections.add(section)
        end
      end
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <div class="showcase-shell">
        <header class="showcase-hero">
          <div>
            <p class="showcase-kicker">Opal · LF::UI</p>
            <h1>Standard UI primitives</h1>
            <p>Accessible, server-rendered components with a precompiled Tailwind theme.</p>
          </div>
          #{LF::UI.badge("Preview", tone: LF::UI::Tone::Primary, size: LF::UI::Size::Large)}
        </header>

        <main class="showcase-grid">
          #{actions_card}
          #{feedback_card}
          #{interaction_card}
          #{advanced_components_card}
          #{form_card}
          #{table_card}
        </main>
        #{release_dialog}
        #{notifications}
      </div>
    HTML
  end

  def title : String?
    "Opal UI showcase"
  end

  def render_document(live_root : String, client_script : String) : String
    <<-HTML
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <link rel="icon" href="data:,">
          <title>#{title}</title>
          #{LF::UI.stylesheet_tag.value}
          <style>
            :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
            * { box-sizing: border-box; }
            body { margin: 0; background: #f8fafc; color: #0f172a; }
            .showcase-shell { width: min(72rem, calc(100% - 2rem)); margin: 0 auto; padding: 3rem 0; }
            .showcase-hero { display: flex; align-items: start; justify-content: space-between; gap: 2rem; margin-bottom: 2rem; }
            .showcase-hero h1 { margin: .25rem 0 .5rem; font-size: clamp(2rem, 5vw, 3.5rem); letter-spacing: -.04em; }
            .showcase-hero p { margin: 0; color: #475569; }
            .showcase-kicker { font-size: .75rem; font-weight: 700; letter-spacing: .14em; text-transform: uppercase; }
            .showcase-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1.25rem; align-items: start; }
            .showcase-wide { grid-column: 1 / -1; }
            .showcase-stack { display: grid; gap: 1rem; }
            .showcase-actions { display: flex; flex-wrap: wrap; gap: .75rem; }
            .showcase-badges { display: flex; flex-wrap: wrap; gap: .5rem; }
            .showcase-form { display: grid; gap: 1rem; }
            .showcase-form-actions { display: flex; align-items: center; gap: .75rem; }
            #opal-live-root.phx-loading::before { content: "Reconnecting…"; display: block; padding: .5rem 1rem; background: #fef3c7; color: #92400e; }
            @media (max-width: 48rem) { .showcase-grid { grid-template-columns: 1fr; } .showcase-wide { grid-column: auto; } }
            @media (prefers-color-scheme: dark) {
              body { background: #020617; color: #f8fafc; }
              .showcase-hero p { color: #94a3b8; }
            }
          </style>
        </head>
        <body>#{live_root}#{LF::UI.hook_script_tag.value}#{client_script}</body>
      </html>
    HTML
  end

  private def actions_card : LF::LiveView::Rendered
    actions = String.build do |html|
      html << LF::UI.button(
        @deployment_ready ? "Mark pending" : "Mark ready",
        attributes: {"id" => "deployment-toggle", "phx-click" => "toggle_deployment"}
      ).to_html
      html << LF::UI.button(
        "Secondary",
        variant: LF::UI::ButtonVariant::Outline,
        tone: LF::UI::Tone::Neutral
      ).to_html
      html << LF::UI.button(
        "Delete",
        variant: LF::UI::ButtonVariant::Ghost,
        tone: LF::UI::Tone::Danger
      ).to_html
      html << LF::UI.button(
        "Open release dialog",
        variant: LF::UI::ButtonVariant::Outline,
        attributes: {"id" => "open-release-dialog", "phx-click" => "open_release_dialog"}
      ).to_html
      html << LF::UI.link_button(
        "Documentation",
        "https://github.com/mikeoz32/opal",
        variant: LF::UI::ButtonVariant::Outline,
        tone: LF::UI::Tone::Primary
      ).to_html
      html << LF::UI.button("Disabled", disabled: true).to_html
      unless @last_dialog_close_reason.blank?
        html << LF::UI.badge(
          "Closed by #{@last_dialog_close_reason}",
          attributes: {"id" => "dialog-close-reason", "aria-live" => "polite"}
        ).to_html
      end
    end
    header = LF::UI.card_header(
      LF::LiveView::HTML.raw(
        LF::UI.card_title("Actions").to_html +
        LF::UI.card_description("Buttons and links share typed variants, tones, and sizes.").to_html
      )
    )
    body = LF::UI.card_body(
      LF::LiveView::HTML.raw(%(<div class="showcase-actions">#{actions}</div>))
    )
    LF::UI.card(LF::LiveView::HTML.raw(header.to_html + body.to_html))
  end

  private def feedback_card : LF::LiveView::Rendered
    badges = String.build do |html|
      LF::UI::Tone.each do |tone|
        html << LF::UI.badge(tone.to_s, tone: tone).to_html
      end
    end
    status = if @deployment_ready
               LF::UI.alert(
                 "All release gates passed.",
                 title: "Ready to deploy",
                 tone: LF::UI::Tone::Success,
                 live: true,
                 attributes: {"id" => "deployment-status"}
               )
             else
               LF::UI.alert(
                 "Run the remaining checks before publishing.",
                 title: "Deployment pending",
                 tone: LF::UI::Tone::Warning,
                 live: true,
                 attributes: {"id" => "deployment-status"}
               )
             end
    content = LF::LiveView::HTML.raw(<<-HTML)
      <div class="showcase-stack">
        <div class="showcase-badges">#{badges}</div>
        #{status.to_html}
      </div>
    HTML
    header = LF::UI.card_header(LF::UI.card_title("Feedback"))
    body = LF::UI.card_body(content)
    LF::UI.card(LF::LiveView::HTML.raw(header.to_html + body.to_html))
  end

  private def form_card : LF::LiveView::Rendered
    name_error = @validation_count > 0 && @name.blank? ? "Name is required" : nil
    role_error = @validation_count > 0 && @role.blank? ? "Choose a role" : nil
    controls = String.build do |html|
      html << LF::UI.input(
        "Name",
        id: "profile-name",
        name: "name",
        value: @name,
        autocomplete: "name",
        hint: "Shown to other workspace members.",
        error: name_error,
        required: true,
        attributes: {"data-testid" => "profile-name"}
      ).to_html
      html << LF::UI.select(
        "Role",
        [
          LF::UI::SelectOption.new("admin", "Administrator"),
          LF::UI::SelectOption.new("editor", "Editor"),
          LF::UI::SelectOption.new("viewer", "Viewer"),
        ],
        id: "profile-role",
        name: "role",
        selected: @role,
        prompt: "Choose a role",
        error: role_error,
        required: true
      ).to_html
      html << LF::UI.textarea(
        "Notes",
        id: "profile-notes",
        name: "notes",
        hint: "Optional context for the team."
      ).to_html
      html << LF::UI.checkbox(
        "Send a weekly summary",
        id: "weekly-summary",
        name: "weekly_summary",
        checked: true
      ).to_html
      html << LF::UI.switch(
        "Real-time notifications",
        id: "notifications-switch",
        checked: @notifications,
        attributes: {"phx-click" => "toggle_notifications"}
      ).to_html
      html << %(<div class="showcase-form-actions">)
      html << LF::UI.button("Save profile", type: "submit", attributes: {"id" => "save-profile"}).to_html
      if @saved
        html << LF::UI.badge(
          "Saved",
          tone: LF::UI::Tone::Success,
          attributes: {"id" => "saved-status", "aria-live" => "polite"}
        ).to_html
      end
      html << "</div>"
    end
    form = LF::LiveView::HTML.raw(<<-HTML)
      <form class="showcase-form" phx-change="validate_profile" phx-debounce="100" phx-submit="save_profile">
        #{controls}
      </form>
    HTML
    header = LF::UI.card_header(
      LF::LiveView::HTML.raw(
        LF::UI.card_title("Profile form").to_html +
        LF::UI.card_description("Labels, hints, validation errors, and ARIA wiring are included.").to_html
      )
    )
    body = LF::UI.card_body(form)
    LF::UI.card(
      LF::LiveView::HTML.raw(header.to_html + body.to_html),
      class_name: "showcase-wide",
      attributes: {"id" => "profile-card"}
    )
  end

  private def interaction_card : LF::LiveView::Rendered
    menu_items = LF::LiveView::HTML.raw(
      LF::UI.dropdown_item(
        "Run checks",
        event: "run_menu_action",
        value: "checks",
        attributes: {"id" => "menu-run-checks"}
      ).to_html +
      LF::UI.dropdown_item(
        "Create tag",
        event: "run_menu_action",
        value: "tag",
        attributes: {"id" => "menu-create-tag"}
      ).to_html +
      LF::UI.dropdown_item("Deploy production", disabled: true).to_html +
      LF::UI.dropdown_link("Open documentation", "https://github.com/mikeoz32/opal").to_html
    )
    dropdown = LF::UI.dropdown(
      LF::LiveView::HTML.raw(
        LF::UI.dropdown_trigger(
          "Release actions",
          id: "release-actions-trigger",
          controls: "release-actions-menu"
        ).to_html +
        LF::UI.dropdown_menu(
          menu_items,
          id: "release-actions-menu",
          labelled_by: "release-actions-trigger",
          align: LF::UI::MenuAlign::End
        ).to_html
      ),
      id: "release-actions"
    )

    tab_buttons = String.build do |html|
      {"overview" => "Overview", "activity" => "Activity", "settings" => "Settings"}.each do |value, label|
        html << LF::UI.tab(
          label,
          id: "#{value}-tab",
          panel_id: "#{value}-panel",
          selected: @selected_tab == value,
          select_event: "select_component_tab",
          value: value
        ).to_html
      end
    end
    panels = String.build do |html|
      {
        "overview" => "Current release metadata and readiness.",
        "activity" => "Recent builds and deployment events.",
        "settings" => "Release channel and notification settings.",
      }.each do |value, copy|
        html << LF::UI.tab_panel(
          copy,
          id: "#{value}-panel",
          labelled_by: "#{value}-tab",
          selected: @selected_tab == value
        ).to_html
      end
    end
    tabs = LF::UI.tabs(
      LF::LiveView::HTML.raw(
        LF::UI.tab_list(
          LF::LiveView::HTML.raw(tab_buttons),
          label: "Release details"
        ).to_html + panels
      ),
      id: "release-tabs"
    )

    controls = String.build do |html|
      html << %(<div class="showcase-actions">#{dropdown.to_html})
      html << LF::UI.button(
        "Show notification",
        variant: LF::UI::ButtonVariant::Outline,
        attributes: {"id" => "show-release-toast", "phx-click" => "show_release_toast"}
      ).to_html
      unless @last_menu_action.blank?
        html << LF::UI.badge(
          "Selected #{@last_menu_action}",
          attributes: {"id" => "menu-action-result", "aria-live" => "polite"}
        ).to_html
      end
      unless @last_toast_dismiss_reason.blank?
        html << LF::UI.badge(
          "Toast dismissed by #{@last_toast_dismiss_reason}",
          attributes: {"id" => "toast-dismiss-result", "aria-live" => "polite"}
        ).to_html
      end
      html << "</div>"
    end
    content = LF::LiveView::HTML.raw(
      %(<div class="showcase-stack">#{controls}#{tabs.to_html}</div>)
    )
    header = LF::UI.card_header(
      LF::LiveView::HTML.raw(
        LF::UI.card_title("Interactive primitives").to_html +
        LF::UI.card_description("Dropdown focus is local; tabs and notifications keep application state on the server.").to_html
      )
    )
    body = LF::UI.card_body(content)
    LF::UI.card(
      LF::LiveView::HTML.raw(header.to_html + body.to_html),
      class_name: "showcase-wide"
    )
  end

  private def table_card : LF::LiveView::Rendered
    head = LF::UI.table_head(
      LF::UI.table_row(
        LF::LiveView::HTML.raw(
          LF::UI.table_header("Component").to_html +
          LF::UI.table_header("Kind").to_html +
          LF::UI.table_header("Status").to_html
        )
      )
    )
    rows = String.build do |html|
      {
        "Button"     => "Action",
        "Input"      => "Form",
        "Table"      => "Data",
        "Accordion"  => "Disclosure",
        "Tooltip"    => "Overlay",
        "Pagination" => "Navigation",
      }.each do |name, kind|
        cells = LF::UI.table_cell(name).to_html +
                LF::UI.table_cell(kind).to_html +
                LF::UI.table_cell(LF::UI.badge("Ready", tone: LF::UI::Tone::Success)).to_html
        html << LF::UI.table_row(LF::LiveView::HTML.raw(cells)).to_html
      end
    end
    table = LF::UI.table(
      LF::LiveView::HTML.raw(head.to_html + LF::UI.table_body(LF::LiveView::HTML.raw(rows)).to_html),
      caption: "UI primitive implementation status"
    )
    header = LF::UI.card_header(LF::UI.card_title("Component status"))
    body = LF::UI.card_body(table)
    LF::UI.card(
      LF::LiveView::HTML.raw(header.to_html + body.to_html),
      class_name: "showcase-wide"
    )
  end

  private def advanced_components_card : LF::LiveView::Rendered
    accordion_items = String.build do |html|
      {
        "checks"    => {"Release checks", "All required checks passed on the current candidate."},
        "artifacts" => {"Build artifacts", "Packages and documentation are ready for publication."},
        "rollback"  => {"Rollback plan", "Keep the previous release available until verification completes."},
        "archived"  => {"Archived release", "Archived releases cannot be changed."},
      }.each do |value, copy|
        trigger_id = "#{value}-accordion-trigger"
        panel_id = "#{value}-accordion-panel"
        expanded = @expanded_sections.includes?(value)
        trigger = LF::UI.accordion_trigger(
          copy[0],
          id: trigger_id,
          panel_id: panel_id,
          expanded: expanded,
          toggle_event: "toggle_accordion",
          value: value,
          disabled: value == "archived"
        )
        panel = LF::UI.accordion_panel(
          copy[1],
          id: panel_id,
          labelled_by: trigger_id,
          expanded: expanded
        )
        html << LF::UI.accordion_item(
          LF::LiveView::HTML.raw(trigger.to_html + panel.to_html)
        ).to_html
      end
    end
    accordion = LF::UI.accordion(
      LF::LiveView::HTML.raw(accordion_items),
      id: "release-accordion",
      label: "Release preparation"
    )

    tooltip = LF::UI.tooltip(
      "?",
      "Arrow keys move between accordion headings without changing server-owned expansion state.",
      id: "accordion-help",
      trigger_label: "About accordion keyboard controls",
      position: LF::UI::TooltipPosition::Right,
      delay_ms: 150
    )

    pages = String.build do |html|
      html << LF::UI.pagination_link(
        "Previous",
        "/?page=#{@current_page - 1}",
        label: "Previous page",
        disabled: @current_page == 1,
        live_patch: true
      ).to_html
      1.upto(5) do |page|
        html << LF::UI.pagination_link(
          page.to_s,
          "/?page=#{page}",
          label: "Page #{page}",
          current: @current_page == page,
          live_patch: true
        ).to_html
      end
      html << LF::UI.pagination_link(
        "Next",
        "/?page=#{@current_page + 1}",
        label: "Next page",
        disabled: @current_page == 5,
        live_patch: true
      ).to_html
    end
    pagination = LF::UI.pagination(
      LF::LiveView::HTML.raw(pages),
      label: "Release history pages",
      attributes: {"id" => "release-pagination"}
    )

    content = LF::LiveView::HTML.raw(<<-HTML)
      <div class="showcase-stack">
        <div class="showcase-form-actions">
          <strong>Release preparation</strong>
          #{tooltip.to_html}
        </div>
        #{accordion.to_html}
        <output id="pagination-status" aria-live="polite">Page #{@current_page} of 5</output>
        #{pagination.to_html}
      </div>
    HTML
    header = LF::UI.card_header(
      LF::LiveView::HTML.raw(
        LF::UI.card_title("Disclosure and navigation").to_html +
        LF::UI.card_description("Accordion expansion and pagination live in the URL-backed application state; tooltip visibility stays local.").to_html
      )
    )
    body = LF::UI.card_body(content)
    LF::UI.card(
      LF::LiveView::HTML.raw(header.to_html + body.to_html),
      class_name: "showcase-wide",
      attributes: {"id" => "advanced-components-card"}
    )
  end

  private def release_dialog : LF::LiveView::Rendered
    header = LF::UI.dialog_header(
      LF::LiveView::HTML.raw(
        LF::UI.dialog_title("Publish release", id: "release-dialog-title").to_html +
        LF::UI.dialog_description(
          "Review the current release state before publishing.",
          id: "release-dialog-description"
        ).to_html
      )
    )
    body = LF::UI.dialog_body(
      LF::LiveView::HTML.raw(
        %(<p id="dialog-revision">Dialog update #{@dialog_revision}</p>)
      )
    )
    footer = LF::UI.dialog_footer(
      LF::LiveView::HTML.raw(
        LF::UI.button(
          "Refresh preview",
          variant: LF::UI::ButtonVariant::Outline,
          attributes: {"id" => "refresh-release-dialog", "phx-click" => "refresh_release_dialog"}
        ).to_html +
        LF::UI.button(
          "Close dialog",
          attributes: {
            "id"               => "close-release-dialog",
            "autofocus"        => "",
            "phx-click"        => "close_release_dialog",
            "phx-value-reason" => "button",
          }
        ).to_html
      )
    )
    LF::UI.dialog(
      LF::LiveView::HTML.raw(header.to_html + body.to_html + footer.to_html),
      id: "release-dialog",
      open: @release_dialog_open,
      labelled_by: "release-dialog-title",
      described_by: "release-dialog-description",
      close_event: "close_release_dialog",
      return_focus: "open-release-dialog"
    )
  end

  private def notifications : LF::LiveView::Rendered
    content = if @toast_visible
                LF::UI.toast(
                  "The release candidate passed its local checks.",
                  id: "release-toast-#{@toast_sequence}",
                  title: "Release ready",
                  tone: LF::UI::Tone::Success,
                  dismiss_event: "dismiss_release_toast",
                  auto_dismiss_ms: 5_000,
                  return_focus: "show-release-toast"
                )
              else
                LF::LiveView::Rendered.opaque("")
              end
    LF::UI.toast_region(content, id: "showcase-notifications")
  end

  private def update_profile(value : JSON::Any) : Nil
    fields = value.as_h
    @name = fields["name"]?.try(&.as_s) || ""
    @role = fields["role"]?.try(&.as_s) || ""
  rescue TypeCastError
    @name = ""
    @role = ""
  end

  private def string_value(value : JSON::Any, key : String) : String
    value.as_h[key]?.try(&.as_s) || ""
  rescue TypeCastError
    ""
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class UIShowcaseApplication
end
