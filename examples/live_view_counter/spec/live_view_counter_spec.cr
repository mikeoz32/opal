require "spec"
require "../src/live_view_counter"

describe CounterLive do
  it "renders escaped form state and handles counter events" do
    view = CounterLive.new(CounterLabel.new)
    request = HTTP::Request.new("GET", "/?start=2")
    view.mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))

    view.handle_event("increment", JSON.parse("{}"))
    view.handle_event("save_name", JSON.parse(%({"name":"<Mike>"})))

    view.render.should contain(">3</output>")
    view.render.should contain("&lt;Mike&gt;")
    view.title.should eq("Counter 3 · Opal")
  end
end
