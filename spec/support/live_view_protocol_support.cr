require "../spec_helper"
require "../../src/opal"
require "http/client"

class LiveViewSpecCounter < LF::LiveView::View
  @count = 0
  @connected = false

  def mount(context : LF::LiveView::MountContext) : Nil
    @connected = context.connected?
  end

  def render : LF::LiveView::Rendered
    connected = @connected ? "yes" : "no"
    LF::LiveView::HTML.rendered(
      %(<button id="spec-counter" phx-click="increment">#{@count}</button><span>#{connected}</span>)
    )
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment"
      @count += 1
    else
      super
    end
  end

  def title : String?
    "Counter #{@count}"
  end
end

class LiveViewSpecForbidden < LF::LiveView::View
  def mount(context : LF::LiveView::MountContext) : Nil
    raise LF::HTTP::Forbidden.new if context.connected?
  end

  def render : String
    "initially allowed"
  end
end

class LiveViewSpecPush < LF::LiveView::View
  @@mounted = Channel(LiveViewSpecPush).new(1)

  def self.reset : Nil
    @@mounted = Channel(LiveViewSpecPush).new(1)
  end

  def self.wait_until_mounted : LiveViewSpecPush
    @@mounted.receive
  end

  @value = 0

  def mount(context : LF::LiveView::MountContext) : Nil
    @@mounted.send(self) if context.connected?
  end

  def push(value : Int32) : Nil
    send_info("set", JSON::Any.new(value.to_i64))
  end

  def handle_info(name : String, value : JSON::Any) : Nil
    case name
    when "set"
      @value = value.as_i.to_i
    else
      super
    end
  end

  def render : String
    %(<output>#{@value}</output>)
  end
end

class LiveViewSpecDisposable < LF::LiveView::View
  include LF::DI::Disposable

  @@destroyed = Channel(Nil).new(2)

  def self.reset : Nil
    @@destroyed = Channel(Nil).new(2)
  end

  def self.wait_until_destroyed : Nil
    select
    when @@destroyed.receive
    when timeout(2.seconds)
      fail "unmanaged LiveView was not destroyed"
    end
  end

  def render : String
    "disposable"
  end

  def destroy : Nil
    @@destroyed.send(nil)
  end
end

class LiveViewSpecHeaderGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    context.request.headers["X-Live-Access"]? == "allowed"
  end
end

class LiveViewSpecFailure < LF::LiveView::View
  def render : String
    "failure"
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    raise "application failure"
  end
end

class LiveViewSpecNestedComponent < LF::LiveView::Component
  include LF::DI::Disposable

  @@mount_count = 0
  @@destroy_count = 0
  @@lifecycle = [] of String

  def self.reset : Nil
    @@mount_count = 0
    @@destroy_count = 0
    @@lifecycle.clear
  end

  def self.mount_count : Int32
    @@mount_count
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  def self.lifecycle : Array(String)
    @@lifecycle.dup
  end

  def self.clear_lifecycle : Nil
    @@lifecycle.clear
  end

  def self.record_lifecycle(entry : String) : Nil
    @@lifecycle << entry
  end

  @count = 0
  @owner = ""

  def mount : Nil
    @@mount_count += 1
  end

  def update(assigns : JSON::Any) : Nil
    @owner = assigns.as_h["owner"].as_s
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(
      %(<button id="nested-component-#{@owner.downcase}" phx-target="#{myself}" phx-click="increment_nested">#{@owner} nested:#{@count}</button>)
    )
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    if event == "increment_nested"
      @count += 1
    else
      super
    end
  end

  def destroy : Nil
    @@destroy_count += 1
    @@lifecycle << "child:#{@owner}"
  end
end

class LiveViewSpecRecursiveComponent < LF::LiveView::Component
  include LF::DI::Disposable

  @@destroy_count = 0

  def self.reset : Nil
    @@destroy_count = 0
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  def render : LF::LiveView::Rendered
    child = live_component(LiveViewSpecRecursiveComponent, id) do
      LiveViewSpecRecursiveComponent.new
    end
    LF::LiveView::HTML.rendered(%(<div>#{child}</div>))
  end

  def destroy : Nil
    @@destroy_count += 1
  end
end

class LiveViewSpecRecursiveComponents < LF::LiveView::View
  def render : LF::LiveView::Rendered
    live_component(LiveViewSpecRecursiveComponent, "cycle") do
      LiveViewSpecRecursiveComponent.new
    end
  end
end

class LiveViewSpecDeepComponent < LF::LiveView::Component
  include LF::DI::Disposable

  @@destroy_count = 0

  def self.reset : Nil
    @@destroy_count = 0
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  @remaining = 0

  def update(assigns : JSON::Any) : Nil
    @remaining = assigns.as_h["remaining"].as_i.to_i
  end

  def render : LF::LiveView::Rendered
    return LF::LiveView::Rendered.opaque("leaf") if @remaining.zero?

    child = live_component(
      LiveViewSpecDeepComponent,
      @remaining.to_s,
      {remaining: @remaining - 1}
    ) do
      LiveViewSpecDeepComponent.new
    end
    LF::LiveView::HTML.rendered(%(<div>#{child}</div>))
  end

  def destroy : Nil
    @@destroy_count += 1
  end
end

class LiveViewSpecDeepComponents < LF::LiveView::View
  def render : LF::LiveView::Rendered
    live_component(LiveViewSpecDeepComponent, "root", {remaining: LF::LiveView::View::MAX_COMPONENT_DEPTH}) do
      LiveViewSpecDeepComponent.new
    end
  end
end

class LiveViewSpecComponent < LF::LiveView::Component
  include LF::DI::Disposable

  @@mount_count = 0
  @@update_count = 0
  @@destroy_count = 0

  def self.reset : Nil
    @@mount_count = 0
    @@update_count = 0
    @@destroy_count = 0
  end

  def self.mount_count : Int32
    @@mount_count
  end

  def self.update_count : Int32
    @@update_count
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  @count = 0
  @label = ""
  @show_nested = true

  def mount : Nil
    @@mount_count += 1
  end

  def update(assigns : JSON::Any) : Nil
    @@update_count += 1
    @label = assigns.as_h["label"].as_s
  end

  def render : LF::LiveView::Rendered
    nested = if @show_nested
               live_component(LiveViewSpecNestedComponent, "shared", {owner: @label}) do
                 LiveViewSpecNestedComponent.new
               end
             else
               LF::LiveView::Rendered.opaque("")
             end

    LF::LiveView::HTML.rendered(
      %(<section id="component-#{id}" phx-target="#{myself}"><button phx-click="increment">#{@label}:#{@count}</button><button phx-click="toggle_nested">toggle nested</button>#{nested}</section>)
    )
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment"
      @count += 1
    when "patch_parent"
      push_patch("/components?source=component")
    when "hook_reply"
      push_event("component_notice", {id: id, count: @count})
      reply({id: id, count: @count})
    when "toggle_nested"
      @show_nested = !@show_nested
    else
      super
    end
  end

  def destroy : Nil
    @@destroy_count += 1
    LiveViewSpecNestedComponent.record_lifecycle("parent:#{@label}")
  end
end

class LiveViewSpecHooks < LF::LiveView::View
  @message = "waiting"

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "hook_event"
      @message = value.as_h["message"].as_s
      push_event("hook_notice", {message: @message})
      reply({accepted: true, message: @message})
    when "null_reply"
      reply
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(
      %(<output id="hook-state" phx-hook="SpecHook">#{@message}</output>)
    )
  end
end

class LiveViewSpecComponents < LF::LiveView::View
  @show_right = true

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "toggle_right"
      @show_right = !@show_right
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    left = live_component(LiveViewSpecComponent, "left", {label: "Left"}) do
      LiveViewSpecComponent.new
    end
    right = if @show_right
              live_component(LiveViewSpecComponent, "right", {label: "Right"}) do
                LiveViewSpecComponent.new
              end
            else
              LF::LiveView::Rendered.opaque("")
            end

    LF::LiveView::HTML.rendered(
      %(<section>#{left}#{right}<button phx-click="toggle_right">toggle</button></section>)
    )
  end
end

class LiveViewSpecStreams < LF::LiveView::View
  def mount(context : LF::LiveView::MountContext) : Nil
    stream_reset("spec-stream")
    stream_insert("spec-stream", "stream-1", item("stream-1", "First"))
    stream_insert("spec-stream", "stream-2", item("stream-2", "Second"))
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "prepend"
      stream_insert("spec-stream", "stream-3", item("stream-3", "Third"), at: 0, limit: 2)
    when "update"
      stream_insert("spec-stream", "stream-1", item("stream-1", "First updated"))
    when "delete"
      stream_delete("spec-stream", "stream-2")
    when "reset"
      stream_reset("spec-stream")
      stream_insert("spec-stream", "stream-9", item("stream-9", "Reset item"))
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    contents = stream_contents("spec-stream")
    LF::LiveView::HTML.rendered(
      %(<ul id="spec-stream" phx-update="stream">#{contents}</ul>)
    )
  end

  private def item(id : String, label : String) : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(%(<li id="#{id}">#{label}</li>))
  end
end

class LiveViewSpecKeyed < LF::LiveView::View
  @items = [
    {"first", "First"},
    {"second", "Second"},
    {"third", "Third"},
  ]

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "reverse"
      @items.reverse!
    when "reverse_update"
      @items.reverse!
      @items.map! do |id, label|
        {id, id == "third" ? "Third updated" : label}
      end
    when "update_second"
      @items.map! do |id, label|
        {id, id == "second" ? "Second updated" : label}
      end
    when "remove_third"
      @items.reject! { |id, _label| id == "third" }
    when "append_fourth"
      @items << {"fourth", "Fourth"}
    when "clear"
      @items.clear
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    items = LF::LiveView::HTML.keyed(@items) do |item|
      id, label = item
      {id, LF::LiveView::HTML.rendered(%(<li id="keyed-#{id}">#{label}</li>))}
    end
    LF::LiveView::HTML.rendered(
      %(<ul id="keyed-spec">#{items}</ul>)
    )
  end
end

class LiveViewSpecGrandchild < LF::LiveView::View
  include LF::DI::Disposable

  @@destroy_count = 0

  def self.reset : Nil
    @@destroy_count = 0
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  @count = 0
  @label = ""

  def mount(context : LF::LiveView::MountContext) : Nil
    @label = context.session.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    if event == "increment_grandchild"
      @count += 1
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(
      %(<button id="spec-grandchild-button" phx-click="increment_grandchild">#{@label}:#{@count}</button>)
    )
  end

  def destroy : Nil
    @@destroy_count += 1
  end
end

class LiveViewSpecChild < LF::LiveView::View
  include LF::DI::Disposable

  @@destroy_count = 0

  def self.reset : Nil
    @@destroy_count = 0
  end

  def self.destroy_count : Int32
    @@destroy_count
  end

  @count = 0
  @label = ""
  @show_grandchild = true

  def mount(context : LF::LiveView::MountContext) : Nil
    @label = context.session.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_child"
      @count += 1
    when "toggle_grandchild"
      @show_grandchild = !@show_grandchild
    when "fail_child"
      raise "child failure"
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    grandchild = if @show_grandchild
                   live_view(
                     LiveViewSpecGrandchild,
                     "spec-grandchild",
                     {label: "Grandchild"}
                   ) { LiveViewSpecGrandchild.new }
                 else
                   ""
                 end
    LF::LiveView::HTML.rendered(
      %(<section><button id="spec-child-button" phx-click="increment_child">#{@label}:#{@count}</button>#{grandchild}</section>)
    )
  end

  def destroy : Nil
    @@destroy_count += 1
  end
end

class LiveViewSpecChildren < LF::LiveView::View
  @count = 0
  @show_child = true

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_parent"
      @count += 1
    when "toggle_child"
      @show_child = !@show_child
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    child = if @show_child
              live_view(LiveViewSpecChild, "spec-child", {label: "Child"}) do
                LiveViewSpecChild.new
              end
            else
              ""
            end
    LF::LiveView::HTML.rendered(
      %(<main><button id="spec-parent-button" phx-click="increment_parent">Parent:#{@count}</button>#{child}<button phx-click="toggle_child">toggle child</button></main>)
    )
  end
end

class LiveViewSpecChildHostComponent < LF::LiveView::Component
  def render : LF::LiveView::Rendered
    child = live_view(
      LiveViewSpecGrandchild,
      "component-child-view",
      {label: "Component child"}
    ) { LiveViewSpecGrandchild.new }
    LF::LiveView::HTML.rendered(%(<section>#{child}</section>))
  end
end

class LiveViewSpecComponentChildHost < LF::LiveView::View
  def render : LF::LiveView::Rendered
    live_component(LiveViewSpecChildHostComponent, "host") do
      LiveViewSpecChildHostComponent.new
    end
  end
end

class LiveViewSpecNavigation < LF::LiveView::View
  @section = ""
  @tab = ""
  @connected = false

  def mount(context : LF::LiveView::MountContext) : Nil
    @connected = context.connected?
  end

  def handle_params(context : LF::LiveView::ParamsContext) : Nil
    @section = context.params["section"]
    @tab = context.query_params["tab"]? || "default"
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "server_patch"
      push_patch("/navigation/server?tab=pushed")
    when "server_replace"
      push_patch("/navigation/replaced?tab=pushed", replace: true)
    when "server_navigate"
      push_navigate("/counter?from=navigation")
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    connected = @connected ? "yes" : "no"
    LF::LiveView::HTML.rendered(
      %(<output id="navigation-state">#{@section}:#{@tab}:#{connected}</output>)
    )
  end

  def title : String?
    "#{@section} · #{@tab}"
  end
end

class LiveViewSpecNavigationGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    context.route_params["section"]? != "blocked" &&
      context.request.query_params["tab"]? != "blocked"
  end
end

def live_view_spec_server(
  secret : String,
  *,
  max_message_bytes = 64 * 1024,
  join_timeout = 10.seconds,
  idle_timeout = 75.seconds,
  &block : Socket::IPAddress ->
)
  LiveViewSpecPush.reset
  LiveViewSpecDisposable.reset
  LiveViewSpecComponent.reset
  LiveViewSpecNestedComponent.reset
  LiveViewSpecChild.reset
  LiveViewSpecGrandchild.reset
  root = LF::DI::DefaultContainer.new
  endpoint = LF::LiveView::Endpoint.new(
    secret,
    max_message_bytes: max_message_bytes,
    join_timeout: join_timeout,
    idle_timeout: idle_timeout
  )
  endpoint.page("/counter", LiveViewSpecCounter) { |_scope| LiveViewSpecCounter.new }
  endpoint.page("/forbidden", LiveViewSpecForbidden) { |_scope| LiveViewSpecForbidden.new }
  endpoint.page("/push", LiveViewSpecPush) { |_scope| LiveViewSpecPush.new }
  endpoint.page("/disposable", LiveViewSpecDisposable) { |_scope| LiveViewSpecDisposable.new }
  endpoint.page("/failure", LiveViewSpecFailure) { |_scope| LiveViewSpecFailure.new }
  endpoint.page("/components", LiveViewSpecComponents) { |_scope| LiveViewSpecComponents.new }
  endpoint.page("/streams", LiveViewSpecStreams) { |_scope| LiveViewSpecStreams.new }
  endpoint.page("/keyed", LiveViewSpecKeyed) { |_scope| LiveViewSpecKeyed.new }
  endpoint.page("/children", LiveViewSpecChildren) { |_scope| LiveViewSpecChildren.new }
  endpoint.page("/component-child", LiveViewSpecComponentChildHost) do |_scope|
    LiveViewSpecComponentChildHost.new
  end
  endpoint.page("/hooks", LiveViewSpecHooks) { |_scope| LiveViewSpecHooks.new }
  endpoint.page(
    "/navigation/:section",
    LiveViewSpecNavigation,
    guards: ->(_scope : LF::DI::Container) do
      [LiveViewSpecNavigationGuard.new.as(LF::HTTP::Guard)]
    end
  ) { |_scope| LiveViewSpecNavigation.new }
  endpoint.page(
    "/guarded",
    LiveViewSpecCounter,
    name: "GuardedCounter",
    guards: ->(_scope : LF::DI::Container) do
      [LiveViewSpecHeaderGuard.new.as(LF::HTTP::Guard)]
    end
  ) { |_scope| LiveViewSpecCounter.new }
  app = LF::HTTP::App.new do |router|
    endpoint.mount(router)
  end
  connections = LF::HTTP::WebSocketConnectionRegistry.new
  server = HTTP::Server.new([
    LF::HTTP::DI::WebSocketScopeHandler.new(root, "websocket", connections),
    LF::HTTP::DI::RequestScopeHandler.new(root),
    app,
  ])
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  yield address
ensure
  server.try(&.close)
  connections.try(&.shutdown(1_000))
  root.try(&.shutdown)
end
