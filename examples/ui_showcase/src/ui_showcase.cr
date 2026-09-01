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
          #{form_card}
          #{table_card}
        </main>
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
        <body>#{live_root}#{client_script}</body>
      </html>
    HTML
  end

  private def actions_card : LF::LiveView::Rendered
    actions = String.build do |html|
      html << LF::UI.button(
        @deployment_ready ? "Mark pending" : "Mark ready",
        attributes: {"id" => "deployment-toggle", "data-opal-click" => "toggle_deployment"}
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
      html << LF::UI.link_button(
        "Documentation",
        "https://github.com/mikeoz32/opal",
        variant: LF::UI::ButtonVariant::Outline,
        tone: LF::UI::Tone::Primary
      ).to_html
      html << LF::UI.button("Disabled", disabled: true).to_html
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
        attributes: {"data-opal-click" => "toggle_notifications"}
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
      <form class="showcase-form" data-opal-change="validate_profile" data-opal-debounce="100" data-opal-submit="save_profile">
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
      {"Button" => "Action", "Input" => "Form", "Table" => "Data"}.each do |name, kind|
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

  private def update_profile(value : JSON::Any) : Nil
    fields = value.as_h
    @name = fields["name"]?.try(&.as_s) || ""
    @role = fields["role"]?.try(&.as_s) || ""
  rescue TypeCastError
    @name = ""
    @role = ""
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class UIShowcaseApplication
end
