require "./spec_helper"
require "../src/opal"
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
      %(<button id="spec-counter" data-opal-click="increment">#{@count}</button><span>#{connected}</span>)
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

  def mount : Nil
    @@mount_count += 1
  end

  def update(assigns : JSON::Any) : Nil
    @@update_count += 1
    @label = assigns.as_h["label"].as_s
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(
      %(<button id="component-#{id}" data-opal-target="#{myself}" data-opal-click="increment">#{@label}:#{@count}</button>)
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

  def destroy : Nil
    @@destroy_count += 1
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
      %(<section>#{left}#{right}<button data-opal-click="toggle_right">toggle</button></section>)
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
      %(<ul id="spec-stream" data-opal-stream>#{contents}</ul>)
    )
  end

  private def item(id : String, label : String) : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(%(<li id="#{id}" data-opal-key="#{id}">#{label}</li>))
  end
end

private def live_view_spec_server(
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

describe LF::LiveView do
  it "escapes HTML text and attributes" do
    LF::LiveView::HTML.escape(%(<Mike & "Opal">)).should eq("&lt;Mike &amp; &quot;Opal&quot;&gt;")
  end

  it "renders escaped structural templates and diffs only changed dynamics" do
    unsafe = %(<Mike & "Opal">)
    initial = LF::LiveView::HTML.rendered(%(<p>#{unsafe}: #{1}</p>))
    updated = LF::LiveView::HTML.rendered(%(<p>#{unsafe}: #{2}</p>))

    initial.to_html.should eq("<p>&lt;Mike &amp; &quot;Opal&quot;&gt;: 1</p>")
    initial.statics.size.should eq(3)
    initial.dynamics.should eq(["&lt;Mike &amp; &quot;Opal&quot;&gt;", "1"])
    updated.diff(initial).should eq({1 => "2"})
    LF::LiveView::HTML.rendered(%(<section>#{unsafe}: #{2}</section>)).diff(initial).should be_nil
    LF::LiveView::HTML.rendered(%(<p>#{LF::LiveView::HTML.raw("<em>trusted</em>")}</p>)).to_html
      .should eq("<p><em>trusted</em></p>")
  end

  it "signs mount state and rejects tampering and expired tokens" do
    tokens = LF::LiveView::MountToken.new("s" * 32, 1.hour)
    token = tokens.sign("Counter", {"id" => "7"}, "/counter?id=7")

    mount = tokens.verify(token)
    mount.route.should eq("Counter")
    mount.params.should eq({"id" => "7"})
    mount.resource.should eq("/counter?id=7")

    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token.sub('C', 'X'))
    end
    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token, Time.utc + 2.hours)
    end
  end

  it "honors sub-second mount-token ages" do
    now = Time.utc
    tokens = LF::LiveView::MountToken.new("m" * 32, 500.milliseconds)
    token = tokens.sign("Counter", {} of String => String, "/counter", now)

    tokens.verify(token, now + 499.milliseconds).route.should eq("Counter")
    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token, now + 501.milliseconds)
    end
  end

  it "requires a strong mount-token secret" do
    expect_raises(LF::LiveView::ConfigurationError, "at least 32 bytes") do
      LF::LiveView::MountToken.new("short")
    end
  end

  it "rejects page paths that collide with an existing GET route" do
    endpoint = LF::LiveView::Endpoint.new("h" * 32)
    endpoint.page("/counter", LiveViewSpecCounter) { |_scope| LiveViewSpecCounter.new }
    router = LF::HTTP::Router.new
    router.get("//counter/") { |_context, _params| }

    expect_raises(LF::LiveView::ConfigurationError, "conflicts with an existing route") do
      endpoint.mount(router)
    end
  end

  it "renders over HTTP and serves its dependency-free browser client" do
    live_view_spec_server("a" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter?source=spec")
      response.status.should eq(HTTP::Status::OK)
      response.headers["Content-Type"].should eq("text/html; charset=utf-8")
      response.body.should contain("data-opal-live-root")
      response.body.should contain(%(<span>no</span>))
      response.body.should contain(%(<script type="module" src="/_opal/live.js">))

      client = HTTP::Client.get("http://#{address.address}:#{address.port}/_opal/live.js")
      client.status.should eq(HTTP::Status::OK)
      client.body.should contain("export class OpalLiveView")
      client.body.should_not contain("phoenix")
    end
  end

  it "mounts connected state, handles ordered events, and answers heartbeats" do
    live_view_spec_server("b" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: headers
      )

      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      joined = JSON.parse(websocket.receive.as(String))
      joined["type"].as_s.should eq("render")
      joined["protocol"].as_i64.should eq(1)
      joined["version"].as_i64.should eq(0)
      joined["html"].as_s.should contain(%(<span>yes</span>))

      websocket.send({
        type:    "event",
        event:   "increment",
        value:   {source: "spec"},
        version: 0,
        ref:     1,
      }.to_json)
      rendered = JSON.parse(websocket.receive.as(String))
      rendered["version"].as_i64.should eq(1)
      rendered["ref"].as_i64.should eq(1)
      rendered["status"].as_s.should eq("ok")
      rendered["html"].as_s.should contain(">1</button>")
      rendered["title"].as_s.should eq("Counter 1")

      websocket.send({type: "heartbeat", ref: 9}.to_json)
      heartbeat = JSON.parse(websocket.receive.as(String))
      heartbeat["type"].as_s.should eq("heartbeat")
      heartbeat["ref"].as_i64.should eq(9)
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "negotiates protocol v2 and sends only changed dynamic fragments" do
    live_view_spec_server("d" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: headers
      )

      websocket.send({type: "join", protocol: 2, token: token}.to_json)
      joined = JSON.parse(websocket.receive.as(String))
      joined["protocol"].as_i64.should eq(2)
      joined["version"].as_i64.should eq(0)
      joined["html"]?.should be_nil
      snapshot = joined["rendered"].as_h
      snapshot["fingerprint"].as_s.should_not be_empty
      snapshot["statics"].as_a.size.should eq(3)
      snapshot["dynamics"].as_a.map(&.as_s).should eq(["0", "yes"])

      websocket.send({
        type:    "event",
        event:   "increment",
        value:   nil,
        version: 0,
        ref:     1,
      }.to_json)
      rendered = JSON.parse(websocket.receive.as(String))
      rendered["protocol"].as_i64.should eq(2)
      rendered["version"].as_i64.should eq(1)
      rendered["rendered"]?.should be_nil
      rendered["fingerprint"].as_s.should eq(snapshot["fingerprint"].as_s)
      rendered["diff"].as_h.should eq({"0" => JSON::Any.new("1")})
      rendered["ref"].as_i64.should eq(1)
      rendered["status"].as_s.should eq("ok")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "keeps stateful component instances and routes events by component target" do
    live_view_spec_server("k" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/components")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      response.body.should contain("Left:0")
      response.body.should contain("Right:0")
      LiveViewSpecComponent.mount_count.should eq(2)
      LiveViewSpecComponent.destroy_count.should eq(2)

      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 2, token: token}.to_json)
      joined = JSON.parse(websocket.receive.as(String))
      dynamics = joined["rendered"].as_h["dynamics"].as_a.map(&.as_s)
      left_target = dynamics[0].match(/data-opal-target="(\d+)"/).not_nil![1].to_i64
      right_target = dynamics[1].match(/data-opal-target="(\d+)"/).not_nil![1].to_i64
      left_target.should_not eq(right_target)
      LiveViewSpecComponent.mount_count.should eq(4)

      websocket.send({
        type:    "event",
        event:   "increment",
        target:  left_target,
        value:   nil,
        version: 0,
        ref:     1,
      }.to_json)
      left_update = JSON.parse(websocket.receive.as(String))
      left_update["diff"].as_h.keys.should eq(["0"])
      left_update["diff"].as_h["0"].as_s.should contain("Left:1")
      left_update["diff"].as_h["0"].as_s.should_not contain("Right:1")

      websocket.send({
        type:    "event",
        event:   "increment",
        target:  right_target,
        value:   nil,
        version: 1,
        ref:     2,
      }.to_json)
      right_update = JSON.parse(websocket.receive.as(String))
      right_update["diff"].as_h.keys.should eq(["1"])
      right_update["diff"].as_h["1"].as_s.should contain("Right:1")

      websocket.send({
        type:    "event",
        event:   "increment",
        target:  999_999,
        value:   nil,
        version: 2,
        ref:     3,
      }.to_json)
      unknown = JSON.parse(websocket.receive.as(String))
      unknown["type"].as_s.should eq("error")
      unknown["reason"].as_s.should eq("unknown_target")
      unknown["ref"].as_i64.should eq(3)

      websocket.send({type: "heartbeat", ref: 10}.to_json)
      JSON.parse(websocket.receive.as(String))["ref"].as_i64.should eq(10)

      websocket.send({
        type:    "event",
        event:   "toggle_right",
        target:  nil,
        value:   nil,
        version: 2,
        ref:     4,
      }.to_json)
      removed = JSON.parse(websocket.receive.as(String))
      removed["version"].as_i64.should eq(3)
      removed["diff"].as_h["1"].as_s.should be_empty
      LiveViewSpecComponent.destroy_count.should eq(3)

      websocket.send({
        type:    "event",
        event:   "toggle_right",
        value:   nil,
        version: 3,
        ref:     5,
      }.to_json)
      restored = JSON.parse(websocket.receive.as(String))
      restored_right = restored["diff"].as_h["1"].as_s
      restored_right.should contain("Right:0")
      restored_target = restored_right.match(/data-opal-target="(\d+)"/).not_nil![1].to_i64
      restored_target.should_not eq(right_target)
      LiveViewSpecComponent.mount_count.should eq(5)
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "sends ordered protocol-v2 stream insert, update, delete, and reset operations" do
    live_view_spec_server("z" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/streams")
      response.body.should contain(%(<li id="stream-1" data-opal-key="stream-1">First</li>))
      response.body.should contain(%(<li id="stream-2" data-opal-key="stream-2">Second</li>))
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]

      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 2, token: token}.to_json)
      joined = JSON.parse(websocket.receive.as(String))
      initial_streams = joined["streams"].as_a
      initial_streams.map { |operation| operation["op"].as_s }.should eq(["reset", "insert", "insert"])
      initial_streams[1]["id"].as_s.should eq("stream-1")
      initial_streams[2]["id"].as_s.should eq("stream-2")

      websocket.send({
        type:    "event",
        event:   "prepend",
        value:   nil,
        version: 0,
        ref:     1,
      }.to_json)
      prepended = JSON.parse(websocket.receive.as(String))
      insert = prepended["streams"].as_a.first
      insert["op"].as_s.should eq("insert")
      insert["id"].as_s.should eq("stream-3")
      insert["at"].as_i.should eq(0)
      insert["limit"].as_i.should eq(2)

      websocket.send({
        type:    "event",
        event:   "update",
        value:   nil,
        version: 1,
        ref:     2,
      }.to_json)
      updated = JSON.parse(websocket.receive.as(String))["streams"].as_a.first
      updated["id"].as_s.should eq("stream-1")
      updated["html"].as_s.should contain("First updated")

      websocket.send({
        type:    "event",
        event:   "delete",
        value:   nil,
        version: 2,
        ref:     3,
      }.to_json)
      deleted = JSON.parse(websocket.receive.as(String))["streams"].as_a.first
      deleted["op"].as_s.should eq("delete")
      deleted["id"].as_s.should eq("stream-2")

      websocket.send({
        type:    "event",
        event:   "reset",
        value:   nil,
        version: 3,
        ref:     4,
      }.to_json)
      reset = JSON.parse(websocket.receive.as(String))["streams"].as_a
      reset.map { |operation| operation["op"].as_s }.should eq(["reset", "insert"])
      reset.last["id"].as_s.should eq("stream-9")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "rejects streams for legacy protocol clients instead of sending partial state" do
    live_view_spec_server("y" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/streams")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      close = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| close.send(code) }

      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive?.should be_nil
      close.receive.should eq(HTTP::WebSocket::CloseCode::ProtocolError)
    ensure
      websocket.try(&.close)
    end
  end

  it "resynchronizes stale events without applying them" do
    live_view_spec_server("c" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive

      websocket.send({type: "event", event: "increment", value: nil, version: 42, ref: 7}.to_json)
      rendered = JSON.parse(websocket.receive.as(String))
      rendered["version"].as_i64.should eq(0)
      rendered["ref"].as_i64.should eq(7)
      rendered["status"].as_s.should eq("stale")
      rendered["html"].as_s.should contain(">0</button>")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "serializes server updates and snapshots changed opaque string renders in v2" do
    live_view_spec_server("g" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/push")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 2, token: token}.to_json)
      initial = JSON.parse(websocket.receive.as(String))
      initial["version"].as_i64.should eq(0)
      initial["rendered"].as_h["statics"].as_a.first.as_s.should contain(">0</output>")

      LiveViewSpecPush.wait_until_mounted.push(7)

      pushed = JSON.parse(websocket.receive.as(String))
      pushed["version"].as_i64.should eq(1)
      pushed["diff"]?.should be_nil
      pushed["rendered"].as_h["statics"].as_a.first.as_s.should contain(">7</output>")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "destroys unmanaged views after disconnected and connected lifecycles" do
    live_view_spec_server("u" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/disposable")
      response.status.should eq(HTTP::Status::OK)
      LiveViewSpecDisposable.wait_until_destroyed

      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive
      websocket.close
      LiveViewSpecDisposable.wait_until_destroyed
    ensure
      websocket.try(&.close)
    end
  end

  it "runs route guards on disconnected and connected mounts" do
    live_view_spec_server("r" * 32) do |address|
      denied = HTTP::Client.get("http://#{address.address}:#{address.port}/guarded")
      denied.status.should eq(HTTP::Status::FORBIDDEN)

      allowed_headers = HTTP::Headers{"X-Live-Access" => "allowed"}
      allowed = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/guarded",
        headers: allowed_headers
      )
      token = allowed.body.match(/data-opal-token="([^"]+)"/).not_nil![1]

      denied_socket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      denied_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      denied_socket.on_close { |code, _reason| denied_close.send(code) }
      denied_socket.send({type: "join", protocol: 1, token: token}.to_json)
      denied_socket.receive?.should be_nil
      denied_close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)

      connected_headers = HTTP::Headers{
        "Origin"        => "http://#{address.address}:#{address.port}",
        "X-Live-Access" => "allowed",
      }
      allowed_socket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: connected_headers
      )
      allowed_socket.send({type: "join", protocol: 1, token: token}.to_json)
      JSON.parse(allowed_socket.receive.as(String))["type"].as_s.should eq("render")
      allowed_socket.close
    ensure
      denied_socket.try(&.close)
      allowed_socket.try(&.close)
    end
  end

  it "rejects binary and oversized protocol messages" do
    live_view_spec_server("l" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}

      binary_socket = HTTP::WebSocket.new("127.0.0.1", "/_opal/live", port: address.port, headers: headers)
      binary_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      binary_socket.on_close { |code, _reason| binary_close.send(code) }
      binary_socket.send(Bytes[1_u8, 2_u8])
      binary_socket.receive?.should be_nil
      binary_close.receive.should eq(HTTP::WebSocket::CloseCode::UnsupportedData)

      large_socket = HTTP::WebSocket.new("127.0.0.1", "/_opal/live", port: address.port, headers: headers)
      large_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      large_socket.on_close { |code, _reason| large_close.send(code) }
      large_socket.send({type: "join", protocol: 1, token: token}.to_json)
      large_socket.receive
      large_socket.send("x" * (64 * 1024 + 1))
      large_socket.receive?.should be_nil
      large_close.receive.should eq(HTTP::WebSocket::CloseCode::MessageTooBig)
    ensure
      binary_socket.try(&.close)
      large_socket.try(&.close)
    end
  end

  it "closes clients that do not join or remain idle" do
    live_view_spec_server("t" * 32, join_timeout: 50.milliseconds, idle_timeout: 100.milliseconds) do |address|
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      join_socket = HTTP::WebSocket.new("127.0.0.1", "/_opal/live", port: address.port, headers: headers)
      join_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      join_socket.on_close { |code, _reason| join_close.send(code) }
      join_socket.receive?.should be_nil
      join_close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)

      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      idle_socket = HTTP::WebSocket.new("127.0.0.1", "/_opal/live", port: address.port, headers: headers)
      idle_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      idle_socket.on_close { |code, _reason| idle_close.send(code) }
      idle_socket.send({type: "join", protocol: 1, token: token}.to_json)
      idle_socket.receive
      idle_socket.receive?.should be_nil
      idle_close.receive.should eq(HTTP::WebSocket::CloseCode::GoingAway)
    ensure
      join_socket.try(&.close)
      idle_socket.try(&.close)
    end
  end

  it "keeps client event values out of failure logs and close reasons" do
    backend = Log::MemoryBackend.new
    Log.setup(:trace, backend)

    live_view_spec_server("v" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/failure")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      websocket = HTTP::WebSocket.new("127.0.0.1", "/_opal/live", port: address.port, headers: headers)
      close = Channel({HTTP::WebSocket::CloseCode, String}).new(1)
      websocket.on_close { |code, reason| close.send({code, reason}) }
      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive
      websocket.send({
        type:    "event",
        event:   "user-controlled-secret",
        value:   {token: "also-secret"},
        version: 0,
        ref:     1,
      }.to_json)
      websocket.receive?.should be_nil

      code, reason = close.receive
      code.should eq(HTTP::WebSocket::CloseCode::InternalServerError)
      reason.should eq("event failed")
      entry = backend.entries.find { |item| item.message.includes?("LiveView event failed") }.not_nil!
      entry.message.should contain("route=LiveViewSpecFailure")
      entry.message.should_not contain("user-controlled-secret")
      entry.message.should_not contain("also-secret")
    ensure
      websocket.try(&.close)
    end
  ensure
    Log.setup(:info)
  end

  it "rejects an unsupported protocol version" do
    live_view_spec_server("e" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      close = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| close.send(code) }

      websocket.send({type: "join", protocol: 3, token: token}.to_json)
      websocket.receive?.should be_nil
      close.receive.should eq(HTTP::WebSocket::CloseCode::ProtocolError)
    ensure
      websocket.try(&.close)
    end
  end

  it "maps connected-mount authorization failures to policy violation" do
    live_view_spec_server("f" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/forbidden")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      close = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| close.send(code) }

      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive?.should be_nil
      close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)
    ensure
      websocket.try(&.close)
    end
  end

  it "rejects a cross-origin handshake before upgrading" do
    live_view_spec_server("d" * 32) do |address|
      headers = HTTP::Headers{
        "Connection" => "Upgrade",
        "Upgrade"    => "websocket",
        "Origin"     => "https://evil.example",
      }
      response = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/_opal/live",
        headers: headers
      )

      response.status.should eq(HTTP::Status::FORBIDDEN)
    end
  end
end
