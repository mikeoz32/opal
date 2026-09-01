require "./spec_helper"
require "../src/opal"

private class ConnectionRuntimeSpecComponent < LF::LiveView::Component
  include LF::DI::Disposable

  @@destroy_count = 0

  def self.reset : Nil
    @@destroy_count = 0
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  @count = 0

  def render : LF::LiveView::Rendered
    LF::LiveView::Rendered.opaque(
      %(<button data-opal-target="#{myself}">#{connected?}:#{@count}</button>)
    )
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    if event == "increment"
      @count += 1
    else
      super
    end
  end

  def destroy : Nil
    @@destroy_count += 1
  end
end

describe LF::LiveView::ConnectionRuntime do
  it "isolates component, navigation, event, and stream state per connection" do
    ConnectionRuntimeSpecComponent.reset
    first = LF::LiveView::ConnectionRuntime.new
    second = LF::LiveView::ConnectionRuntime.new
    first.prepare_mount(true)
    second.prepare_mount(false)

    first_render = first.render do
      first.render_component(
        ConnectionRuntimeSpecComponent.name,
        "counter",
        JSON::Any.new(nil),
        -> { ConnectionRuntimeSpecComponent.new.as(LF::LiveView::Component) }
      )
    end
    second_render = second.render do
      second.render_component(
        ConnectionRuntimeSpecComponent.name,
        "counter",
        JSON::Any.new(nil),
        -> { ConnectionRuntimeSpecComponent.new.as(LF::LiveView::Component) }
      )
    end
    first_render.to_html.should contain("true:0")
    second_render.to_html.should contain("false:0")

    first.handle_event(1_i64, "increment", JSON::Any.new(nil)) { fail "unexpected view event" }
    first.render do
      first.render_component(
        ConnectionRuntimeSpecComponent.name,
        "counter",
        JSON::Any.new(nil),
        -> { ConnectionRuntimeSpecComponent.new.as(LF::LiveView::Component) }
      )
    end.to_html.should contain("true:1")
    second.render do
      second.render_component(
        ConnectionRuntimeSpecComponent.name,
        "counter",
        JSON::Any.new(nil),
        -> { ConnectionRuntimeSpecComponent.new.as(LF::LiveView::Component) }
      )
    end.to_html.should contain("false:0")

    first.navigate(LF::LiveView::Navigation.patch("/first"))
    first.push_event(LF::LiveView::PushedEvent.new("notice", JSON::Any.new("first")))
    first.stream_insert("items", "item-1", LF::LiveView::Rendered.opaque(%(<li id="item-1">first</li>)))

    first.take_navigation.not_nil!.to.should eq("/first")
    second.take_navigation.should be_nil
    first.take_pushed_events.map(&.name).should eq(["notice"])
    second.take_pushed_events.should be_empty
    first.stream_contents("items").value.should contain("first")
    second.stream_contents("items").value.should be_empty
  ensure
    first.try(&.disconnect)
    second.try(&.disconnect)
    ConnectionRuntimeSpecComponent.destroy_count.should eq(2)
  end

  it "releases connection dispatchers on disconnect" do
    runtime = LF::LiveView::ConnectionRuntime.new
    infos = [] of LF::LiveView::Info
    refreshes = 0
    runtime.connect(
      ->(info : LF::LiveView::Info) { infos << info; true },
      -> { refreshes += 1; true }
    )

    runtime.send_info(LF::LiveView::Info.new("tick")).should be_true
    runtime.refresh.should be_true
    infos.map(&.name).should eq(["tick"])
    refreshes.should eq(1)

    runtime.disconnect
    runtime.send_info(LF::LiveView::Info.new("late")).should be_false
    runtime.refresh.should be_false
  end

  it "rolls unacknowledged stream mutations back to the committed render" do
    runtime = LF::LiveView::ConnectionRuntime.new
    runtime.stream_reset("items")
    runtime.stream_insert(
      "items",
      "item-1",
      LF::LiveView::Rendered.opaque(%(<li id="item-1">first</li>))
    )
    runtime.take_stream_operations

    runtime.stream_insert(
      "items",
      "item-2",
      LF::LiveView::Rendered.opaque(%(<li id="item-2">second</li>))
    )
    runtime.clear_stream_operations

    contents = runtime.stream_contents("items").value
    contents.should contain("item-1")
    contents.should_not contain("item-2")
  ensure
    runtime.try(&.disconnect)
  end

  it "encodes update-only inserts and validates stream consumption" do
    runtime = LF::LiveView::ConnectionRuntime.new
    runtime.stream_reset("items")
    runtime.stream_insert(
      "items",
      "item-1",
      LF::LiveView::Rendered.opaque(%(<li id="item-1">first</li>))
    )
    runtime.stream_insert(
      "items",
      "item-2",
      LF::LiveView::Rendered.opaque(%(<li id="item-2">second</li>))
    )
    initial = runtime.stream_contents("items")
    initial.to_diff["stream"].as_a[3].as_bool.should be_true
    runtime.take_stream_operations(["items"])
    initial.commit!

    runtime.stream_insert(
      "items",
      "item-missing",
      LF::LiveView::Rendered.opaque(%(<li id="item-missing">missing</li>)),
      limit: 1,
      update_only: true
    )
    update = runtime.stream_contents("items")
    update.value.should_not contain("item-missing")
    update.value.should contain("item-1")
    update.value.should contain("item-2")
    metadata = update.to_diff["stream"].as_a[1].as_a.first.as_a
    metadata[0].as_s.should eq("item-missing")
    metadata[3].as_bool.should be_true

    expect_raises(LF::LiveView::Error, "has pending operations but was not rendered") do
      runtime.take_stream_operations([] of String)
    end
    runtime.take_stream_operations(["items"])

    expect_raises(LF::LiveView::Error, "was rendered more than once") do
      runtime.take_stream_operations(["items", "items"])
    end

    expect_raises(ArgumentError, "root id must match") do
      runtime.stream_insert(
        "items",
        "declared-id",
        LF::LiveView::Rendered.opaque(%(<li id="different-id">invalid</li>))
      )
    end
  ensure
    runtime.try(&.disconnect)
  end
end
