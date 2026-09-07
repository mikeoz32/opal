# --8<-- [start:imports]
require "opal"
require "opal/autoconfig/http"
# --8<-- [end:imports]

# --8<-- [start:view_start]
@[LF::LiveView::Page("/counter")]
class CounterLive < LF::LiveView::View
  @count = 0
  @connected = false

  # --8<-- [end:view_start]

  # --8<-- [start:mount]
  def mount(context : LF::LiveView::MountContext) : Nil
    @connected = context.connected?
  end

  # --8<-- [end:mount]

  # --8<-- [start:view_end]
  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment" then @count += 1
    when "decrement" then @count -= 1
    else                  super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <button phx-click="decrement">-</button>
      <output id="counter-value">#{@count}</output>
      <button phx-click="increment">+</button>
    HTML
  end
end

# --8<-- [end:view_end]

# --8<-- [start:application]
@[LF::Application]
@[LF::AutoConfig::HTTP]
class CounterApplication
end

CounterApplication.run_http
# --8<-- [end:application]
