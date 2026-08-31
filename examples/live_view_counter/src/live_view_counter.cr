require "opal"
require "opal/autoconfig/http"

@[LF::DI::Service]
class CounterLabel
  def heading : String
    "Opal LiveView counter"
  end
end

class CounterComponent < LF::LiveView::Component
  @count = 0
  @label = "Counter"

  def update(assigns : JSON::Any) : Nil
    @label = assigns.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_component"
      @count += 1
    when "decrement_component"
      @count -= 1
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <section id="component-#{id}" data-opal-key="component-#{id}" data-opal-target="#{myself}">
        <h2>#{@label} component</h2>
        <div class="counter">
          <button type="button" data-opal-click="decrement_component" aria-label="Decrement #{@label} component">−</button>
          <output id="#{id}-component-value" aria-live="polite">#{@count}</output>
          <button type="button" data-opal-click="increment_component" aria-label="Increment #{@label} component">+</button>
        </div>
      </section>
    HTML
  end
end

@[LF::LiveView::Page("/")]
class CounterLive < LF::LiveView::View
  @count = 0
  @name = "friend"
  @draft_name = "friend"
  @validation_count = 0
  @empty_title = false
  @items_reversed = false

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
    when "reverse_items"
      @items_reversed = !@items_reversed
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

  def render : LF::LiveView::Rendered
    left_component = live_component(CounterComponent, "left", {label: "Left"}) do
      CounterComponent.new
    end
    right_component = live_component(CounterComponent, "right", {label: "Right"}) do
      CounterComponent.new
    end
    items = [
      {"first", "First keyed item"},
      {"second", "Second keyed item"},
      {"third", "Third keyed item"},
    ]
    items.reverse! if @items_reversed
    items_markup = String.build do |html|
      items.each do |id, label|
        html << %(<li id="item-#{LF::LiveView::HTML.escape(id)}" data-opal-key="#{LF::LiveView::HTML.escape(id)}">)
        html << LF::LiveView::HTML.escape(label) << "</li>"
      end
    end

    LF::LiveView::HTML.rendered(<<-HTML)
      <style>
        :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
        #opal-live-root { max-width: 34rem; margin: 5rem auto; padding: 2rem; }
        .counter { display: flex; align-items: center; gap: 1rem; margin: 2rem 0; }
        button, input { font: inherit; padding: .65rem 1rem; }
        output { min-width: 4ch; text-align: center; font-size: 2rem; }
        .components { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; }
        .components section { border: 1px solid currentColor; border-radius: .5rem; padding: 0 1rem; }
        [data-opal-status="disconnected"]::before { content: "Reconnecting..."; color: #d97706; }
      </style>
      <h1>#{@counter_label.heading}</h1>
      <p>Hello, <strong>#{@name}</strong>.</p>
      <div class="counter">
        <button type="button" data-opal-click="decrement" aria-label="Decrement">−</button>
        <output id="counter-value" aria-live="polite">#{@count}</output>
        <button type="button" data-opal-click="increment" aria-label="Increment">+</button>
        <button type="button" data-opal-click="increment_later">+1 later</button>
        <button type="button" data-opal-click="clear_title">Clear title</button>
      </div>
      <form data-opal-change="validate_name" data-opal-debounce="150" data-opal-submit="save_name">
        <label>
          Name
          <input id="name" name="name" value="#{@draft_name}" autocomplete="off">
        </label>
        <button type="submit">Save</button>
      </form>
      <output id="validation-count" data-testid="validation-count">#{@validation_count}</output>
      <div class="components">#{left_component}#{right_component}</div>
      <button type="button" data-opal-click="reverse_items">Reverse keyed items</button>
      <ul id="keyed-items">#{LF::LiveView::HTML.raw(items_markup)}</ul>
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
