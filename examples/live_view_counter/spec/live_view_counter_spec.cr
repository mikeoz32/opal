require "spec"
require "../src/live_view_counter"

describe CounterLive do
  it "renders escaped form state and handles counter events" do
    view = CounterLive.new(CounterLabel.new)
    request = HTTP::Request.new("GET", "/?start=2")
    view.__opal_mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))
    view.__opal_handle_params(LF::LiveView::ParamsContext.new({} of String => String, request.resource))

    view.__opal_handle_event(nil, "increment", JSON.parse("{}"))
    view.__opal_handle_event(nil, "save_name", JSON.parse(%({"name":"<Mike>"})))

    rendered = view.__opal_render.to_html
    rendered.should contain(">3</output>")
    rendered.should contain("&lt;Mike&gt;")
    rendered.should contain("Left component")
    rendered.should contain("Right component")
    rendered.should contain("Left nested component")
    rendered.should contain("Right nested component")
    rendered.should contain(%(id="left-nested-component"))
    rendered.should contain(%(id="right-nested-component"))
    rendered.should contain(%(data-phx-link="patch"))
    rendered.should contain(%(data-phx-component="1"))
    rendered.should contain(%(data-opal-hook="CounterHook"))
    view.title.should eq("Counter 3 · Opal")
  ensure
    view.try(&.__opal_disconnect)
  end
end
