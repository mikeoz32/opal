require "opal"
require "opal/autoconfig/http"

@[LF::DI::Service]
class CounterLabel
  def heading : String
    "Opal LiveView counter"
  end
end

@[LF::LiveView::Page("/")]
class CounterLive < LF::LiveView::View
  @count = 0
  @name = "friend"
  @draft_name = "friend"
  @validation_count = 0
  @empty_title = false

  def initialize(@counter_label : CounterLabel)
  end

  def mount(context : LF::LiveView::MountContext) : Nil
    if start = context.query_params["start"]?
      @count = start.to_i? || 0
    end
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment"
      @count += 1
    when "decrement"
      @count -= 1
    when "increment_later"
      spawn do
        sleep 250.milliseconds
        send_info("increment")
      end
    when "validate_name"
      @draft_name = string_value(value, "name")
      @validation_count += 1
    when "save_name"
      @draft_name = string_value(value, "name")
      @name = @draft_name unless @draft_name.blank?
    when "clear_title"
      @empty_title = true
    else
      super
    end
  end

  def handle_info(name : String, value : JSON::Any) : Nil
    case name
    when "increment"
      @count += 1
    else
      super
    end
  end

  def render : String
    name = LF::LiveView::HTML.escape(@name)
    draft_name = LF::LiveView::HTML.escape(@draft_name)
    heading = LF::LiveView::HTML.escape(@counter_label.heading)
    <<-HTML
      <style>
        :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
        #opal-live-root { max-width: 34rem; margin: 5rem auto; padding: 2rem; }
        .counter { display: flex; align-items: center; gap: 1rem; margin: 2rem 0; }
        button, input { font: inherit; padding: .65rem 1rem; }
        output { min-width: 4ch; text-align: center; font-size: 2rem; }
        [data-opal-status="disconnected"]::before { content: "Reconnecting..."; color: #d97706; }
      </style>
      <h1>#{heading}</h1>
      <p>Hello, <strong>#{name}</strong>.</p>
      <div class="counter">
        <button type="button" data-opal-click="decrement" aria-label="Decrement">−</button>
        <output aria-live="polite">#{@count}</output>
        <button type="button" data-opal-click="increment" aria-label="Increment">+</button>
        <button type="button" data-opal-click="increment_later">+1 later</button>
        <button type="button" data-opal-click="clear_title">Clear title</button>
      </div>
      <form data-opal-change="validate_name" data-opal-debounce="150" data-opal-submit="save_name">
        <label>
          Name
          <input id="name" name="name" value="#{draft_name}" autocomplete="off">
        </label>
        <button type="submit">Save</button>
      </form>
      <output data-testid="validation-count">#{@validation_count}</output>
    HTML
  end

  def title : String?
    @empty_title ? "" : "Counter #{@count} · Opal"
  end

  private def string_value(value : JSON::Any, key : String) : String
    value.as_h[key]?.try(&.as_s) || ""
  rescue TypeCastError
    ""
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class LiveViewCounterApplication
end
